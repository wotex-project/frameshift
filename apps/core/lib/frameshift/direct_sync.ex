defmodule Frameshift.DirectSync do
  @moduledoc """
  Synchronizes an immutable still through admitted frame Forms and state checks.

  `sync/5` receives a validated Wotex Thing Description, artifact, ephemeral
  credential, binding configuration and explicit execution context. It selects
  advertised Forms, reads current state, installs missing binary bytes and writes
  desired state under the strong revision ETag before observing the state again.

  ## Reference-binding semantics

  Wotex owns TD admission, relative-IRI resolution, operation matching and Form
  selection. This module supplies exact artifact URI-template expansion, binary
  digest fields, bounded problem decoding and reference desired/state semantics.
  Retries are limited to explicitly supported safe cases; an uncertain mutation
  is not an invitation to mint another request ID.

  Only matching `currentAsset` and `displayState: displayed` yield `:displayed`.
  An accepted request without that evidence remains `:pending`. `observe/6`
  performs read-only reconciliation for an existing digest/request ID and never
  reposts desired state. `Frameshift.DirectDelivery` owns durable intent/reference
  updates; this synchronizer keeps only transient session and transport context.
  """

  alias Frameshift.Digest
  alias Frameshift.DirectSync.Artifact
  alias Frameshift.Protocol.{JSON, Schema, Thing}
  alias Wotex.Binding.HTTP.{Config, Headers, Request, Response}
  alias Wotex.Form
  alias Wotex.Runtime.{Context, Retry, Selection}
  alias Wotex.ThingDescription

  @control_bytes 64 * 1024
  @maximum_header_count 64
  @maximum_header_bytes 64 * 8 * 1024
  @maximum_uri_bytes 1_024
  @maximum_request_id_bytes 128
  @retryable_transport_reasons [:connection_failed, :request_failed, :response_failed, :timeout]
  @problem_codes %{
    "authentication-required" => :authentication_required,
    "pair-mode-required" => :pair_mode_required,
    "unsupported-protocol" => :unsupported_protocol,
    "unsupported-profile" => :unsupported_profile,
    "asset-too-large" => :asset_too_large,
    "digest-mismatch" => :digest_mismatch,
    "asset-missing" => :asset_missing,
    "state-precondition" => :state_precondition,
    "request-id-conflict" => :request_id_conflict,
    "storage-full" => :storage_full,
    "display-failed" => :display_failed,
    "power-insufficient" => :power_insufficient
  }

  @type outcome :: %{
          outcome: :displayed | :pending,
          installation: :created | :present | :not_required,
          request_id: String.t(),
          state: map()
        }

  defmodule Session do
    @moduledoc """
    Holds the transient inputs and selected Forms for one direct synchronization.

    The session binds immutable artifact, target profile, binding configuration,
    execution context, selected interactions and resolved credential. Installation
    status tracks only the current attempt; authoritative displayed state is read
    through the selected frame Property.

    ## Credential lifetime

    `Frameshift.DirectSync` constructs and consumes this value during a call.
    Inspection omits all fields because both artwork and credentials are present.
    It is not persisted as a command receipt, durable intent or recovery snapshot;
    `Frameshift.DirectDelivery` owns those references without copying key material.
    """

    @type t :: %__MODULE__{
            artifact: term(),
            config: term(),
            context: term(),
            credential: term(),
            profile: term(),
            selections: term(),
            installation: term()
          }

    @derive {Inspect, only: []}
    @enforce_keys [:artifact, :config, :context, :credential, :profile, :selections]
    defstruct @enforce_keys ++ [installation: nil]
  end

  @doc """
  Synchronizes one immutable artifact with a push capable frame.

  The frame's admitted Thing Description selects every request Form. The
  operation reads current state, installs missing bytes, writes desired state
  under a strong ETag, then reads back authoritative display state. A pending
  result means the request was accepted but display has not been confirmed.
  """
  @spec sync(ThingDescription.t(), Artifact.t(), term(), Config.t(), Context.t()) ::
          {:ok, outcome()} | {:error, atom()}
  def sync(
        %ThingDescription{} = td,
        %Artifact{} = artifact,
        credential,
        %Config{} = config,
        %Context{} = context
      ) do
    with :ok <- validate_context(context),
         :ok <- validate_artifact(artifact),
         {:ok, selections} <- select_forms(td, artifact.media_type),
         {:ok, profile} <- validate_target(td, selections.install, artifact),
         {:ok, initial} <- read_state(selections.state, credential, config, context) do
      session = %Session{
        artifact: artifact,
        config: config,
        context: context,
        credential: credential,
        profile: profile,
        selections: selections
      }

      converge(initial, session)
    end
  end

  def sync(_, _, _, _, _),
    do: {:error, :invalid_sync_arguments}

  @doc "Reads the selected frame state without replaying an uncertain mutation."
  @spec observe(ThingDescription.t(), String.t(), String.t(), term(), Config.t(), Context.t()) ::
          {:ok, :displayed | :pending | :not_applied} | {:error, atom()}
  def observe(
        %ThingDescription{} = td,
        digest,
        request_id,
        credential,
        %Config{} = config,
        %Context{} = context
      )
      when is_binary(digest) and is_binary(request_id) do
    with :ok <- validate_observation(digest, request_id, context),
         {:ok, json_profile} <- Thing.reference_https_profile(),
         {:ok, state_form} <-
           Thing.select_frame(td, :property, "state", :readproperty, [json_profile]),
         {:ok, observed} <- read_state(state_form, credential, config, context) do
      {:ok, observed_outcome(observed.state, digest, request_id)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def observe(_, _, _, _, _, _),
    do: {:error, :invalid_sync_arguments}

  defp validate_observation(digest, request_id, context) do
    with :ok <- validate_context(context),
         true <- Digest.valid_sha256?(digest) and request_id == context.request_id do
      :ok
    else
      false -> {:error, :invalid_sync_arguments}
      {:error, reason} -> {:error, reason}
    end
  end

  defp observed_outcome(
         %{"currentAsset" => digest, "displayState" => "displayed"},
         digest,
         _
       ),
       do: :displayed

  defp observed_outcome(
         %{"desiredAsset" => digest, "pendingRequestId" => request_id, "displayState" => state},
         digest,
         request_id
       )
       when state in ["preparing", "refreshing", "recovering"],
       do: :pending

  defp observed_outcome(_, _, _), do: :not_applied

  defp validate_context(%Context{request_id: request_id, deadline: deadline}) do
    cond do
      not is_binary(request_id) or byte_size(request_id) not in 1..@maximum_request_id_bytes ->
        {:error, :invalid_request_id}

      is_nil(deadline) ->
        {:error, :deadline_required}

      true ->
        :ok
    end
  end

  defp validate_artifact(%Artifact{} = artifact) do
    case Artifact.new(
           artifact.bytes,
           artifact.digest,
           artifact.profile_id,
           artifact.media_type
         ) do
      {:ok, verified} when verified.byte_count == artifact.byte_count -> :ok
      _ -> {:error, :invalid_artifact}
    end
  end

  defp select_forms(td, artifact_media_type) do
    with {:ok, json_profile} <- Thing.reference_https_profile(),
         {:ok, artifact_profile} <-
           Thing.reference_https_artifact_profile([artifact_media_type]),
         {:ok, state} <-
           Thing.select_frame(td, :property, "state", :readproperty, [json_profile]),
         {:ok, install} <-
           Thing.select_frame(td, :action, "installAsset", :invokeaction, [artifact_profile]),
         {:ok, desired} <-
           Thing.select_frame(td, :action, "setDesired", :invokeaction, [json_profile]) do
      {:ok, %{state: state, install: install, desired: desired}}
    else
      {:error, _} -> {:error, :compatible_binding_unavailable}
    end
  end

  defp validate_target(td, install_selection, artifact) do
    document = ThingDescription.to_map(td)
    capabilities = document["frameshift:capabilities"]

    with true <- is_map(capabilities),
         :ok <- validate_push_mode(capabilities),
         %{"storage" => storage} <- capabilities,
         profiles when is_list(profiles) <- storage["artifactProfiles"],
         profile when is_map(profile) <-
           Enum.find(profiles, &(&1["id"] == artifact.profile_id)),
         true <- profile["mediaType"] == artifact.media_type,
         true <- artifact.byte_count <= storage["maximumAssetBytes"],
         true <- artifact.byte_count <= profile["maximumAssetBytes"],
         :ok <- validate_install_form(install_selection, artifact) do
      {:ok, profile}
    else
      false -> {:error, :artifact_incompatible}
      nil -> {:error, :unsupported_profile}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_capabilities}
    end
  end

  defp validate_push_mode(%{"transferModes" => modes}) when is_list(modes) do
    if "push" in modes, do: :ok, else: {:error, :compatible_binding_unavailable}
  end

  defp validate_push_mode(_), do: {:error, :invalid_capabilities}

  defp validate_install_form(%Selection{} = selection, artifact) do
    form = Form.to_map(selection.form)
    variables = selection.affordance["uriVariables"]

    cond do
      form["frameshift:artifactProfile"] != artifact.profile_id ->
        {:error, :artifact_profile_form_mismatch}

      normalize_media_type(form["contentType"]) != normalize_media_type(artifact.media_type) ->
        {:error, :artifact_media_type_form_mismatch}

      not valid_digest_variable?(variables) ->
        {:error, :artifact_digest_variable_missing}

      true ->
        validate_method(form, "PUT")
    end
  end

  defp valid_digest_variable?(%{
         "digest" => %{
           "type" => "string",
           "pattern" => "^[0-9a-f]{64}$"
         }
       }),
       do: true

  defp valid_digest_variable?(_), do: false

  defp converge(initial, %Session{} = session) do
    case state_outcome(initial.state, session.artifact.digest) do
      :displayed ->
        success(:displayed, :not_required, initial.state, session.context.request_id)

      :pending ->
        success(:pending, :not_required, initial.state, session.context.request_id)

      {:error, reason} ->
        {:error, reason}

      :needs_sync ->
        with {:ok, installation} <-
               install_with_retry(
                 session.selections.install,
                 session.artifact,
                 session.credential,
                 session.config,
                 session.context,
                 1
               ) do
          set_and_reconcile(initial, %{session | installation: installation}, 1)
        end
    end
  end

  defp install_with_retry(selection, artifact, credential, config, context, attempt) do
    case install_asset(selection, artifact, credential, config, context) do
      {:error, {:transport, reason}} = error ->
        class = transport_class(reason)

        case Retry.decision(:invokeaction, class,
               attempt: attempt,
               max_attempts: 2,
               delay: 0,
               idempotent?: true
             ) do
          {:retry, 0} ->
            install_with_retry(selection, artifact, credential, config, context, attempt + 1)

          :stop ->
            public_transport_error(error)
        end

      result ->
        result
    end
  end

  defp install_asset(selection, artifact, credential, config, context) do
    with {:ok, uri} <- expand_digest_uri(selection.resolved_href, artifact.digest),
         {:ok, digest_field} <- content_digest(artifact.digest),
         {:ok, headers} <-
           request_headers(selection, [
             {"accept", "application/json"},
             {"content-type", artifact.media_type},
             {"content-digest", digest_field},
             {"frameshift-artifact-profile", artifact.profile_id},
             {"if-none-match", "*"}
           ]),
         {:ok, request} <-
           build_request(
             selection,
             "PUT",
             uri,
             headers,
             artifact.bytes,
             artifact.media_type,
             config,
             context
           ),
         {:ok, response} <- call_client(request, credential, config) do
      case Response.status(response) do
        201 -> {:ok, :created}
        204 -> {:ok, :present}
        _ -> response_error(response)
      end
    end
  end

  defp set_and_reconcile(initial, %Session{} = session, attempt) do
    request_body = %{
      "assetDigest" => session.artifact.digest,
      "artifactProfile" => session.profile["id"],
      "requestId" => session.context.request_id
    }

    mutation =
      set_desired(
        session.selections.desired,
        request_body,
        precondition(initial),
        session.credential,
        session.config,
        session.context
      )

    reconcile_mutation(mutation, initial, session, attempt)
  end

  defp set_desired(selection, body, precondition, credential, config, context) do
    form = Form.to_map(selection.form)

    with :ok <- validate_method(form, "PUT"),
         :ok <- Schema.validate("desired", body),
         {:ok, encoded} <- JSON.encode(body),
         true <- byte_size(encoded) <= min(Config.max_request_bytes(config), @control_bytes),
         {:ok, headers} <-
           request_headers(selection, [
             {"accept", "application/json"},
             {"content-type", "application/json"},
             precondition
           ]),
         {:ok, request} <-
           build_request(
             selection,
             "PUT",
             selection.resolved_href,
             headers,
             encoded,
             "application/json",
             config,
             context
           ),
         {:ok, response} <- call_client(request, credential, config) do
      desired_response(response)
    else
      false -> {:error, :request_too_large}
      error -> error
    end
  end

  defp desired_response(response) do
    if Response.status(response) in [200, 202] do
      decode_json_response(response, "state")
    else
      response_error(response)
    end
  end

  defp reconcile_mutation(mutation, initial, %Session{} = session, attempt) do
    case mutation do
      {:ok, _} ->
        reconcile_state(session)

      {:error, {:transport, reason}} ->
        reconcile_uncertain(reason, initial, session, attempt)

      {:error, :invalid_response} ->
        reconcile_state(session)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_uncertain(reason, initial, %Session{} = session, attempt) do
    case read_state(
           session.selections.state,
           session.credential,
           session.config,
           session.context
         ) do
      {:ok, current} ->
        case state_outcome(current.state, session.artifact.digest) do
          :displayed ->
            success(
              :displayed,
              session.installation,
              current.state,
              session.context.request_id
            )

          :pending ->
            success(:pending, session.installation, current.state, session.context.request_id)

          {:error, state_reason} ->
            {:error, state_reason}

          :needs_sync when current.etag == initial.etag and attempt == 1 ->
            retry_desired(reason, current, session)

          :needs_sync ->
            {:error, :activation_outcome_unknown}
        end

      {:error, _} ->
        {:error, :activation_outcome_unknown}
    end
  end

  defp retry_desired(reason, current, %Session{} = session) do
    case Retry.decision(:invokeaction, transport_class(reason),
           attempt: 1,
           max_attempts: 2,
           delay: 0,
           idempotent?: true
         ) do
      {:retry, 0} ->
        set_and_reconcile(current, session, 2)

      :stop ->
        {:error, :activation_outcome_unknown}
    end
  end

  defp reconcile_state(%Session{} = session) do
    case read_state(
           session.selections.state,
           session.credential,
           session.config,
           session.context
         ) do
      {:ok, current} ->
        case state_outcome(current.state, session.artifact.digest) do
          :displayed ->
            success(
              :displayed,
              session.installation,
              current.state,
              session.context.request_id
            )

          :pending ->
            success(:pending, session.installation, current.state, session.context.request_id)

          {:error, reason} ->
            {:error, reason}

          :needs_sync ->
            {:error, :activation_outcome_unknown}
        end

      {:error, _} ->
        {:error, :activation_outcome_unknown}
    end
  end

  defp read_state(selection, credential, config, context) do
    form = Form.to_map(selection.form)

    with :ok <- validate_method(form, "GET"),
         true <- normalize_media_type(form["contentType"]) == "application/json",
         true <- valid_response_media_type?(form, "application/json"),
         {:ok, headers} <- request_headers(selection, [{"accept", "application/json"}]),
         {:ok, request} <-
           build_request(
             selection,
             "GET",
             selection.resolved_href,
             headers,
             nil,
             "application/json",
             config,
             context
           ),
         {:ok, response} <- call_client(request, credential, config),
         {:ok, state} <- state_response(response),
         {:ok, etag} <- strong_etag(response) do
      {:ok, %{state: state, etag: etag}}
    else
      false -> {:error, :invalid_state_form}
      {:error, {:transport, _}} -> {:error, :state_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state_response(response) do
    if Response.status(response) == 200,
      do: decode_json_response(response, "state"),
      else: response_error(response)
  end

  defp state_outcome(%{"currentAsset" => digest, "displayState" => "displayed"}, digest),
    do: :displayed

  defp state_outcome(%{"desiredAsset" => digest, "displayState" => state}, digest)
       when state in ["preparing", "refreshing", "recovering"],
       do: :pending

  defp state_outcome(%{"desiredAsset" => digest, "displayState" => "failed"}, digest),
    do: {:error, :display_failed}

  defp state_outcome(_, _), do: :needs_sync

  defp precondition(%{
         state: %{
           "displayState" => "empty",
           "desiredAsset" => nil,
           "currentAsset" => nil
         }
       }),
       do: {"if-none-match", "*"}

  defp precondition(%{etag: etag}), do: {"if-match", etag}

  defp success(outcome, installation, state, request_id) do
    {:ok,
     %{
       outcome: outcome,
       installation: installation,
       request_id: request_id,
       state: state
     }}
  end

  defp build_request(selection, method, uri, headers, body, media_type, config, context) do
    Request.new(method, uri, headers, body,
      request_id: context.request_id,
      deadline: context.deadline,
      operation: selection.operation,
      media_type: media_type,
      stream?: false,
      max_response_bytes: min(Config.max_response_bytes(config), @control_bytes),
      max_event_bytes: min(Config.max_event_bytes(config), @control_bytes),
      max_header_count: min(Config.max_header_count(config), @maximum_header_count),
      max_header_bytes: min(Config.max_header_bytes(config), @maximum_header_bytes),
      max_uri_bytes: min(Config.max_uri_bytes(config), @maximum_uri_bytes)
    )
    |> normalize_request_result()
  end

  defp normalize_request_result({:ok, request}), do: {:ok, request}
  defp normalize_request_result({:error, _}), do: {:error, :invalid_advertised_form}

  defp request_headers(selection, dynamic) do
    with {:ok, static} <- form_headers(Form.to_map(selection.form)),
         {:ok, runtime} <- Headers.new(dynamic, :request) do
      {:ok, Headers.merge(static, runtime)}
    else
      {:error, _} -> {:error, :invalid_advertised_form}
    end
  end

  defp form_headers(%{"htv:headers" => values}) when is_list(values) do
    values
    |> Enum.map(fn
      %{"htv:fieldName" => name, "htv:fieldValue" => value}
      when is_binary(name) and is_binary(value) ->
        {name, value}

      %{"htv:fieldName" => name} when is_binary(name) ->
        {name, ""}

      _ ->
        :invalid
    end)
    |> Headers.new(:request)
  end

  defp form_headers(%{"htv:headers" => _}),
    do: {:error, :invalid_form_headers}

  defp form_headers(_), do: {:ok, []}

  defp validate_method(form, expected) do
    method = Map.get(form, "htv:methodName", default_method(expected))

    if method == expected,
      do: :ok,
      else: {:error, :invalid_advertised_method}
  end

  defp default_method("GET"), do: "GET"
  defp default_method(_), do: "POST"

  defp expand_digest_uri(uri, digest) do
    hex = String.replace_prefix(digest, "sha256:", "")
    occurrences = length(String.split(uri, "{digest}")) - 1
    without_digest = String.replace(uri, "{digest}", "")

    if occurrences == 1 and not String.contains?(without_digest, ["{", "}"]) do
      {:ok, String.replace(uri, "{digest}", hex)}
    else
      {:error, :invalid_artifact_uri_template}
    end
  end

  defp content_digest("sha256:" <> hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, digest} -> {:ok, "sha-256=:#{Base.encode64(digest)}:"}
      :error -> {:error, :invalid_artifact}
    end
  end

  defp call_client(request, credential, config) do
    {module, client_config} = Config.client(config)

    try do
      module.request(request, credential, client_config)
    rescue
      _ -> {:error, {:transport, :client_exception}}
    catch
      _, _ -> {:error, {:transport, :client_exception}}
    else
      {:ok, %Response{} = response} -> {:ok, response}
      {:error, reason} when is_atom(reason) -> {:error, {:transport, reason}}
      _ -> {:error, {:transport, :client_contract_violation}}
    end
  end

  defp decode_json_response(response, schema) do
    with true <- json_content_type?(Response.headers(response)),
         {:ok, decoded} <- JSON.decode_control(Response.body(response), schema) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp json_content_type?(headers) do
    headers
    |> Headers.get("content-type")
    |> normalize_media_type()
    |> Kernel.==("application/json")
  end

  defp strong_etag(response) do
    etag = Headers.get(Response.headers(response), "etag")

    if is_binary(etag) and byte_size(etag) in 2..256 and
         Regex.match?(~r/^"[\x21\x23-\x7E]*"$/, etag) do
      {:ok, etag}
    else
      {:error, :invalid_etag}
    end
  end

  defp response_error(response) do
    status = Response.status(response)
    headers = Response.headers(response)

    with true <- status in 400..599,
         "application/problem+json" <-
           headers |> Headers.get("content-type") |> normalize_media_type(),
         {:ok, problem} <- JSON.decode_control(Response.body(response), "problem"),
         true <- problem["status"] == status,
         "urn:frameshift:problem:" <> suffix <- problem["type"],
         code when is_atom(code) <- Map.get(@problem_codes, suffix) do
      {:error, code}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_media_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_media_type(_), do: nil

  defp valid_response_media_type?(%{"response" => %{"contentType" => type}}, expected),
    do: normalize_media_type(type) == expected

  defp valid_response_media_type?(_, _), do: true

  defp transport_class(:timeout), do: :timeout
  defp transport_class(reason) when reason in @retryable_transport_reasons, do: :unavailable
  defp transport_class(_), do: :permanent

  defp public_transport_error({:error, {:transport, :timeout}}), do: {:error, :timeout}
  defp public_transport_error({:error, {:transport, _}}), do: {:error, :transport_failure}
end
