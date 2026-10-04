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
  Timeout terminates the task; there is no automatic retry, alternate provider or
  silent cloud fallback. Returned still bytes and dimensions are bounded before
  the library records a master or parent-linked variant with its recipe.

  Provider/model/adapter revisions, target profile, instructions, disclosures and
  reproducibility remain part of the request's recorded meaning. Cache reuse is
  for the canonical recipe, not proof that a provider is available or that a
  best-effort model can regenerate identical bytes. Credentials remain outside
  persistent provenance and diagnostic output.
  """

  alias Frameshift.Digest
  alias Frameshift.Library

  @maximum_instruction_bytes 16 * 1024
  @maximum_result_bytes 256 * 1024 * 1024
  @maximum_dimension 32_768
  @maximum_pixels 100_000_000
  @default_timeout_ms 120_000
  @required_request_fields ~w(
    adapter_revision application_revision base_instruction base_instruction_revision
    disclosure instruction mode model negative_instruction parameters provider_id
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
         :ok <- validate_request_identity(request, provider_id),
         :ok <- validate_request_instructions(request),
         :ok <- validate_request_options(request),
         :ok <- validate_request_parent(request) do
      :ok
    else
      fields when is_list(fields) -> {:error, {:missing_fields, fields}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_request(_, _), do: {:error, :invalid_request}

  defp validate_request_identity(request, provider_id) do
    first_validation_error([
      {request.provider_id == provider_id, :provider_mismatch},
      {bounded_string?(request.provider_id, 128), :invalid_provider_id},
      {bounded_string?(request.model, 256), :invalid_model},
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
      {:ok, master} -> {:ok, Map.put(master, :cache, :hit)}
      :not_found -> run_provider(library, provider, request, context, timeout, recipe_hash)
    end
  end

  defp run_provider(library, provider, request, context, timeout, recipe_hash) do
    task =
      Task.Supervisor.async_nolink(Frameshift.TaskSupervisor, fn ->
        with {:ok, preflight} <- provider.preflight(context),
             :ok <- validate_preflight(preflight, request) do
          provider.generate(request, context)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> persist_result(library, request, recipe_hash, result)
      {:ok, {:error, reason}} -> {:error, {:provider, reason}}
      {:exit, _} -> {:error, :provider_crashed}
      nil -> {:error, :provider_timeout}
    end
  end

  defp validate_preflight(preflight, request) when is_map(preflight) do
    required = ~w(provider_id model destination capabilities disclosures)a
    missing = Enum.reject(required, &Map.has_key?(preflight, &1))

    cond do
      missing != [] ->
        {:error, {:invalid_preflight, {:missing_fields, missing}}}

      preflight.provider_id != request.provider_id ->
        {:error, {:invalid_preflight, :provider_mismatch}}

      preflight.model != request.model ->
        {:error, {:invalid_preflight, :model_mismatch}}

      preflight.destination not in [:local, :cloud] ->
        {:error, {:invalid_preflight, :invalid_destination}}

      Atom.to_string(preflight.destination) != request.disclosure["destination"] ->
        {:error, {:invalid_preflight, :destination_mismatch}}

      not is_map(preflight.capabilities) ->
        {:error, {:invalid_preflight, :invalid_capabilities}}

      not is_map(preflight.disclosures) ->
        {:error, {:invalid_preflight, :invalid_disclosures}}

      true ->
        :ok
    end
  end

  defp validate_preflight(_, _),
    do: {:error, {:invalid_preflight, :invalid_response}}

  defp persist_result(library, request, recipe_hash, result) do
    with :ok <- validate_result(result) do
      attributes = %{
        title: request.title,
        source_kind: :generated,
        width: result.width,
        height: result.height,
        media_type: result.media_type,
        provenance: %{
          "kind" => "ai-generation",
          "model" => request.model,
          "provider" => request.provider_id,
          "resultId" => result.result_id,
          "seed" => request.seed
        }
      }

      result =
        if request[:parent_digest] do
          Library.add_generated_variant(
            library,
            result.bytes,
            attributes,
            request.parent_digest,
            recipe_hash
          )
        else
          Library.add_generated_master(library, result.bytes, attributes, recipe_hash)
        end

      case result do
        {:ok, master} -> {:ok, Map.put(master, :cache, :miss)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_result(result) when is_map(result) do
    with :ok <- validate_result_bytes(result[:bytes]),
         :ok <- validate_result_dimensions(result[:width], result[:height]),
         :ok <- validate_result_media_type(result[:media_type]),
         true <- bounded_string?(result[:result_id], 512) do
      :ok
    else
      false -> {:error, :invalid_result_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_result(_), do: {:error, :invalid_provider_result}

  defp validate_result_bytes(bytes)
       when is_binary(bytes) and byte_size(bytes) > 0 and
              byte_size(bytes) <= @maximum_result_bytes,
       do: :ok

  defp validate_result_bytes(_), do: {:error, :invalid_result_bytes}

  defp validate_result_dimensions(width, height)
       when is_integer(width) and width > 0 and width <= @maximum_dimension and
              is_integer(height) and height > 0 and height <= @maximum_dimension and
              width * height <= @maximum_pixels,
       do: :ok

  defp validate_result_dimensions(_, _), do: {:error, :invalid_result_dimensions}

  defp validate_result_media_type(media_type) do
    if still_media_type?(media_type), do: :ok, else: {:error, :invalid_result_media_type}
  end

  defp still_media_type?(media_type) when is_binary(media_type) do
    media_type in ["image/png", "image/jpeg", "image/heic", "image/avif"]
  end

  defp still_media_type?(_), do: false
end
