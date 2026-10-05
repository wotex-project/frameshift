defmodule Frameshift.Generation do
  @moduledoc """
  Coordinates one explicit still-image provider request and canonical cache.

  `generate/4` validates the selected provider, bounded request and timeout,
  registers a provenance-bearing recipe, then reuses a completed cached result or
  runs the provider. `Frameshift.Generation.Provider` defines preflight and image
  result callbacks; provider context is supplied explicitly and is not persisted
  as recipe data.

  ## Execution and result custody

  Provider work runs under the core task supervisor with a finite deadline.
  Timeout terminates the BEAM task; there is no automatic retry, alternate provider or
  silent cloud fallback. Returned still bytes and dimensions are bounded before
  the library records a canonical master package or parent-linked variant with
  its recipe. The selected platform adapter must supply decoded canonical RGBA8
  and its exact decoder identity; raw provider bytes alone refuse. Edit input is
  derived from a verified active master, never caller-supplied pixels or paths.
  Cache reuse re-verifies the object and package without provider traffic.

  Provider/model/adapter revisions, target profile, instructions, disclosures and
  reproducibility remain part of the request's recorded meaning. Cache reuse is
  for the canonical recipe, not proof that a provider is available or that a
  best-effort model can regenerate identical bytes. Credentials remain outside
  persistent provenance and diagnostic output.

  ## Private callbacks and finite failure

  Provider preflight/generation and result normalization run in a marked private
  task under `Frameshift.NativeCodec.LogPrivacy`; its raw messages and OTP fault
  reports never reach Logger handlers. Conflicting privacy policy refuses new
  work with `:provider_privacy_unavailable`, while verified cached masters remain
  readable. Unavailable task admission returns `:provider_unavailable`.

  Only the declared `Frameshift.Generation.Provider` error atoms reach callers.
  Other error terms map to `:failed`, malformed replies to `:invalid_response`,
  faults to `:provider_crashed` and deadline expiry to `:provider_timeout`. These
  refusals create no generated master and never replace parent/cache bytes. The
  task's exit does not establish native or cloud cancellation; adapter children,
  external effects and their recovery retain independent qualification.
  """

  alias Frameshift.Digest
  alias Frameshift.Generation.NormalizedResult
  alias Frameshift.Library
  alias Frameshift.MasterPackage
  alias Frameshift.NativeCodec.LogPrivacy

  @maximum_instruction_bytes 16 * 1024
  @default_timeout_ms 120_000
  @provider_errors ~w(not_available authentication_failed quota_exhausted refused
    unsupported_model unsupported_request download_required cancelled failed)a
  @required_request_fields ~w(
    adapter_revision application_revision base_instruction base_instruction_revision
    decoder_id decoder_revision disclosure instruction mode model model_revision negative_instruction parameters provider_id
    reproducibility seed target_profile_id target_profile_revision title
  )a

  @doc "Preflights the selected provider and persists a provenance linked generated still."
  @spec generate(GenServer.server(), module(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate(library, provider, request, options \\ []) do
    context = Keyword.get(options, :provider_context, %{})
    timeout = Keyword.get(options, :timeout_ms, @default_timeout_ms)

    with {:ok, provider_id} <- validate_provider(provider),
         :ok <- validate_request(request, provider_id),
         :ok <- validate_timeout(timeout),
         {:ok, recipe_hash} <- register_recipe(library, request) do
      fetch_or_generate(library, provider, request, context, timeout, recipe_hash)
    end
  end

  defp validate_provider(provider) when is_atom(provider) do
    required = [id: 0, preflight: 1, generate: 2]

    with true <- Code.ensure_loaded?(provider),
         true <-
           Enum.all?(required, fn {name, arity} ->
             function_exported?(provider, name, arity)
           end),
         {:ok, provider_id} <- provider_id(provider) do
      {:ok, provider_id}
    else
      _ -> {:error, :invalid_provider}
    end
  end

  defp validate_provider(_), do: {:error, :invalid_provider}

  defp provider_id(provider) do
    {:ok, provider.id()}
  rescue
    _ -> {:error, :invalid_provider}
  catch
    _, _ -> {:error, :invalid_provider}
  end

  defp validate_request(request, provider_id) when is_map(request) do
    missing = Enum.reject(@required_request_fields, &Map.has_key?(request, &1))

    with [] <- missing,
         true <-
           Enum.all?(Map.keys(request), &(&1 in @required_request_fields or &1 == :parent_digest)),
         :ok <- validate_request_identity(request, provider_id),
         :ok <- validate_request_instructions(request),
         :ok <- validate_request_options(request),
         :ok <- validate_request_parent(request) do
      :ok
    else
      fields when is_list(fields) -> {:error, {:missing_fields, fields}}
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_request(_, _), do: {:error, :invalid_request}

  defp validate_request_identity(request, provider_id) do
    first_validation_error([
      {request.provider_id == provider_id, :provider_mismatch},
      {bounded_string?(request.provider_id, 128), :invalid_provider_id},
      {bounded_string?(request.model, 256), :invalid_model},
      {bounded_string?(request.model_revision, 256), :invalid_model_revision},
      {bounded_string?(request.decoder_id, 128), :invalid_decoder_id},
      {bounded_string?(request.decoder_revision, 128), :invalid_decoder_revision},
      {bounded_string?(request.adapter_revision, 128), :invalid_adapter_revision},
      {bounded_string?(request.application_revision, 128), :invalid_application_revision},
      {bounded_string?(request.target_profile_id, 128), :invalid_target_profile_id},
      {bounded_string?(request.target_profile_revision, 128), :invalid_target_profile_revision}
    ])
  end

  defp validate_request_instructions(request) do
    first_validation_error([
      {bounded_optional_string?(request.base_instruction, @maximum_instruction_bytes),
       :invalid_base_instruction},
      {bounded_string?(request.base_instruction_revision, 128),
       :invalid_base_instruction_revision},
      {bounded_string?(request.instruction, @maximum_instruction_bytes), :invalid_instruction},
      {bounded_optional_string?(request.negative_instruction, @maximum_instruction_bytes),
       :invalid_negative_instruction},
      {bounded_string?(request.title, 256), :invalid_title}
    ])
  end

  defp validate_request_options(request) do
    first_validation_error([
      {is_map(request.parameters), :invalid_parameters},
      {valid_disclosure?(request.disclosure), :invalid_disclosure},
      {request.mode in ["generate", "edit"], :invalid_mode},
      {request.reproducibility in ["deterministic", "best_effort"], :invalid_reproducibility},
      {request.seed == nil or is_integer(request.seed), :invalid_seed}
    ])
  end

  defp validate_request_parent(request) do
    first_validation_error([
      {valid_parent?(request[:parent_digest]), :invalid_parent_digest},
      {valid_mode_parent?(request.mode, request[:parent_digest]), :invalid_mode_parent}
    ])
  end

  defp first_validation_error(validations) do
    case Enum.find(validations, fn {valid?, _} -> not valid? end) do
      nil -> :ok
      {_, reason} -> {:error, reason}
    end
  end

  defp bounded_string?(value, maximum) do
    is_binary(value) and value != "" and byte_size(value) <= maximum
  end

  defp bounded_optional_string?(value, maximum) do
    is_binary(value) and byte_size(value) <= maximum
  end

  defp valid_parent?(nil), do: true
  defp valid_parent?(digest), do: Digest.valid_sha256?(digest)

  defp valid_mode_parent?("generate", nil), do: true
  defp valid_mode_parent?("edit", parent_digest), do: is_binary(parent_digest)
  defp valid_mode_parent?(_, _), do: false

  defp valid_disclosure?(%{"destination" => "local", "acknowledged" => acknowledged}),
    do: is_boolean(acknowledged)

  defp valid_disclosure?(%{"destination" => "cloud", "acknowledged" => true}), do: true
  defp valid_disclosure?(_), do: false

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp register_recipe(library, request) do
    parent_digests = if request[:parent_digest], do: [request.parent_digest], else: []

    Library.register_recipe(
      library,
      :generation,
      %{
        "adapterRevision" => request.adapter_revision,
        "applicationRevision" => request.application_revision,
        "baseInstruction" => request.base_instruction,
        "baseInstructionRevision" => request.base_instruction_revision,
        "disclosure" => request.disclosure,
        "instruction" => request.instruction,
        "mode" => request.mode,
        "model" => request.model,
        "modelRevision" => request.model_revision,
        "decoder" => %{"id" => request.decoder_id, "revision" => request.decoder_revision},
        "negativeInstruction" => request.negative_instruction,
        "parameters" => request.parameters,
        "provider" => request.provider_id,
        "reproducibility" => request.reproducibility,
        "seed" => request.seed,
        "targetProfile" => %{
          "id" => request.target_profile_id,
          "revision" => request.target_profile_revision
        }
      },
      parent_digests
    )
  end

  defp fetch_or_generate(library, provider, request, context, timeout, recipe_hash) do
    case Library.cached_generation(library, recipe_hash) do
      {:ok, master} ->
        with {:ok, _} <- NormalizedResult.read_master(library, master["digest"]) do
          {:ok, Map.put(master, :cache, :hit)}
        end

      :not_found ->
        with :ok <- admit_privacy(),
             {:ok, derived} <- NormalizedResult.source_request(library, request) do
          run_provider(library, provider, derived, context, timeout, recipe_hash)
        end
    end
  end

  defp run_provider(library, provider, request, context, timeout, recipe_hash) do
    with {:ok, task} <- start_provider_task(provider, request, context) do
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} -> persist_result(library, request, recipe_hash, result)
        {:ok, {:normalization_error, reason}} -> {:error, reason}
        {:ok, {:provider_error, code}} -> {:error, {:provider, code}}
        {:ok, {:error, reason}} -> {:error, {:provider, reason}}
        {:ok, _} -> {:error, {:provider, :invalid_response}}
        {:exit, _} -> {:error, :provider_crashed}
        nil -> {:error, :provider_timeout}
      end
    end
  end

  defp admit_privacy do
    case LogPrivacy.install() do
      :ok -> :ok
      _ -> {:error, :provider_privacy_unavailable}
    end
  end

  defp start_provider_task(provider, request, context) do
    task =
      Task.Supervisor.async_nolink(Frameshift.TaskSupervisor, fn ->
        :ok = LogPrivacy.mark_current()

        with {:ok, preflight} <- provider_reply(provider.preflight(context)),
             :ok <- validate_preflight(preflight, request),
             {:ok, result} <- provider_reply(provider.generate(request, context)) do
          normalize_result(result, request)
        end
      end)

    {:ok, task}
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    :exit, _ -> {:error, :provider_unavailable}
  end

  defp provider_reply({:ok, _} = result), do: result

  defp provider_reply({:error, reason}) when reason in @provider_errors,
    do: {:provider_error, reason}

  defp provider_reply({:error, _}), do: {:provider_error, :failed}
  defp provider_reply(_), do: {:provider_error, :invalid_response}

  defp normalize_result(result, request) do
    case NormalizedResult.package(result, request) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:normalization_error, reason}
    end
  end

  defp validate_preflight(preflight, request) when is_map(preflight) do
    required =
      ~w(provider_id model model_revision decoder_id decoder_revision destination capabilities disclosures)a

    missing = Enum.reject(required, &Map.has_key?(preflight, &1))

    cond do
      missing != [] ->
        {:error, {:invalid_preflight, {:missing_fields, missing}}}

      preflight.destination not in [:local, :cloud] ->
        {:error, {:invalid_preflight, :invalid_destination}}

      Atom.to_string(preflight.destination) != request.disclosure["destination"] ->
        {:error, {:invalid_preflight, :destination_mismatch}}

      not is_map(preflight.capabilities) ->
        {:error, {:invalid_preflight, :invalid_capabilities}}

      not is_map(preflight.disclosures) ->
        {:error, {:invalid_preflight, :invalid_disclosures}}

      true ->
        validate_preflight_identity(preflight, request)
    end
  end

  defp validate_preflight(_, _),
    do: {:error, {:invalid_preflight, :invalid_response}}

  defp validate_preflight_identity(preflight, request) do
    checks = [
      {preflight.provider_id == request.provider_id, :provider_mismatch},
      {preflight.model == request.model, :model_mismatch},
      {preflight.model_revision == request.model_revision, :model_revision_mismatch},
      {preflight.decoder_id == request.decoder_id and
         preflight.decoder_revision == request.decoder_revision, :decoder_mismatch}
    ]

    case first_validation_error(checks) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_preflight, reason}}
    end
  end

  defp persist_result(library, request, recipe_hash, result) do
    attributes = %{
      title: request.title,
      source_kind: :generated,
      width: result.width,
      height: result.height,
      media_type: MasterPackage.media_type(),
      orientation: 1,
      color_profile: "sRGB",
      provenance: %{
        "kind" => "ai-generation",
        "model" => request.model,
        "modelRevision" => request.model_revision,
        "originalMediaType" => result.media_type,
        "decoder" => %{"id" => request.decoder_id, "revision" => request.decoder_revision},
        "provider" => request.provider_id,
        "resultId" => result.result_id,
        "seed" => request.seed
      }
    }

    result =
      if request[:parent_digest] do
        Library.add_generated_variant(
          library,
          result.master_package,
          attributes,
          request.parent_digest,
          recipe_hash
        )
      else
        Library.add_generated_master(library, result.master_package, attributes, recipe_hash)
      end

    case result do
      {:ok, master} -> {:ok, Map.put(master, :cache, :miss)}
      {:error, reason} -> {:error, reason}
    end
  end
end
