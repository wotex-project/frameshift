defmodule Frameshift.DirectDelivery do
  @moduledoc """
  Joins durable push intent to exact advertised direct-frame interactions.

  `push/6` validates the rendered artifact and selected profile, resolves the
  paired credential transiently and records pending intent through
  `Frameshift.Library` before network mutation. The desired bytes stay protected
  if the call times out or the caller crashes after the frame may have accepted it.

  ## Confirmation and recovery

  `Frameshift.DirectSync` follows admitted Wotex Forms and reads authoritative
  state. Only its matching `:displayed` outcome advances current and
  previous-known-good references; transport success or pending display retains
  unresolved custody. Request identity and payload cannot silently change on replay.

  `reconcile/3` observes the frame's selected read-only state interaction rather
  than resending an uncertain mutation. Credential resolution, protocol refusal
  and unresolved observations return errors/pending state without inventing
  physical completion. The native library owns receipts and immutable artifacts;
  no companion-platform generation or financial runtime participates in this path.
  """

  require Logger

  alias Frameshift.DirectSync
  alias Frameshift.DirectSync.Artifact
  alias Frameshift.Library
  alias Frameshift.Protocol.Thing
  alias Frameshift.Transport.{HTTPClient, MTLSCredential}
  alias Wotex.Binding.HTTP
  alias Wotex.Runtime.Context
  alias Wotex.ThingDescription

  @control_bytes 64 * 1024
  @direct_timeout_ms 10_000

  @doc "Runs one push intent using an explicit credential resolver and selected Forms."
  @spec push(GenServer.server(), map(), map(), map(), String.t(), keyword()) ::
          {:ok, :displayed | :pending} | {:error, term()}
  def push(library, frame, rendered_artifact, profile, request_id, options) do
    with {:ok, resolver} <- resolver(options),
         {:ok, td} <- Thing.parse_frame(frame["td_json"]),
         {:ok, origin} <- frame_origin(td),
         {:ok, bytes} <- artifact_bytes(library, frame, rendered_artifact, profile),
         {:ok, artifact} <-
           Artifact.new(bytes, rendered_artifact["digest"], profile["id"], profile["mediaType"]),
         {:ok, key_material} <- resolve_identity(resolver, frame["credential_ref"]),
         {:ok, credential} <-
           MTLSCredential.new(
             origin,
             frame["server_spki_fingerprint"],
             key_material.certificate,
             key_material.private_key
           ),
         {:ok, config} <- binding_config(options),
         {:ok, context} <- sync_context(request_id),
         {:ok, intent} <-
           Library.begin_direct_delivery(
             library,
             frame["frame_id"],
             artifact.digest,
             artifact.profile_id,
             request_id,
             Map.get(rendered_artifact, :work_digest)
           ) do
      run_attempt(library, frame["frame_id"], request_id, :push, fn attempt_id ->
        synchronize(
          library,
          frame,
          intent,
          td,
          artifact,
          credential,
          config,
          context,
          options,
          attempt_id
        )
      end)
    end
  end

  @doc "Checks an unresolved intent against the frame's advertised read-only state Form."
  @spec reconcile(GenServer.server(), String.t(), keyword()) ::
          {:ok, :displayed | :pending} | {:error, term()}
  def reconcile(library, frame_id, options) when is_binary(frame_id) do
    with {:ok, resolver} <- resolver(options),
         {:ok, frame} <- fetch_frame(library, frame_id),
         {:ok, intent} <- fetch_pending_intent(library, frame_id),
         {:ok, td} <- Thing.parse_frame(frame["td_json"]),
         {:ok, origin} <- frame_origin(td),
         {:ok, key_material} <- resolve_identity(resolver, frame["credential_ref"]),
         {:ok, credential} <-
           MTLSCredential.new(
             origin,
             frame["server_spki_fingerprint"],
             key_material.certificate,
             key_material.private_key
           ),
         {:ok, config} <- binding_config(options),
         {:ok, context} <- sync_context(intent["request_id"]) do
      run_attempt(library, frame_id, intent["request_id"], :reconcile, fn attempt_id ->
        observe_intent(
          library,
          frame_id,
          intent,
          td,
          credential,
          config,
          context,
          options,
          attempt_id
        )
      end)
    end
  end

  def reconcile(_, _, _), do: {:error, :invalid_direct_delivery}

  defp fetch_frame(library, frame_id) do
    case Library.get_paired_frame(library, frame_id) do
      {:ok, frame} -> {:ok, frame}
      :not_found -> {:error, :target_not_found}
    end
  end

  defp fetch_pending_intent(library, frame_id) do
    case Library.direct_delivery(library, frame_id) do
      {:ok, %{"status" => "pending"} = intent} -> {:ok, intent}
      {:ok, _} -> {:error, :direct_delivery_not_pending}
      :not_found -> {:error, :direct_delivery_not_pending}
    end
  end

  defp observe_intent(
         library,
         frame_id,
         intent,
         td,
         credential,
         config,
         context,
         options,
         attempt_id
       ) do
    synchronizer = Keyword.get(options, :synchronizer, DirectSync)

    case synchronizer.observe(
           td,
           intent["desired_digest"],
           intent["request_id"],
           credential,
           config,
           context
         ) do
      {:ok, :displayed} ->
        case Library.finish_direct_delivery(
               library,
               frame_id,
               intent["revision"],
               intent["request_id"],
               intent["desired_digest"],
               :displayed,
               attempt_id
             ) do
          :ok -> {:ok, :displayed}
          {:error, reason} -> {:error, reason}
        end

      {:ok, outcome} when outcome in [:pending, :not_applied] ->
        {:ok, :pending}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :direct_sync_contract_violation}
    end
  rescue
    _ -> {:error, :direct_sync_failure}
  catch
    _, _ -> {:error, :direct_sync_failure}
  end

  defp resolver(options) do
    case Keyword.get(options, :credential_resolver) do
      {module, config} when is_atom(module) and not is_nil(module) -> {:ok, {module, config}}
      _ -> {:error, :credential_broker_unavailable}
    end
  end

  defp frame_origin(td) do
    with %{"base" => base} <- ThingDescription.to_map(td),
         {:ok, uri} <- URI.new(base),
         true <- uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      {:ok, URI.to_string(%{uri | path: nil, query: nil, fragment: nil})}
    else
      _ -> {:error, :invalid_frame_origin}
    end
  end

  defp artifact_bytes(library, frame, rendered_artifact, profile) do
    storage = frame["capabilities"]["storage"]
    ceiling = min(storage["maximumAssetBytes"], profile["maximumAssetBytes"])

    case Library.read_object(library, rendered_artifact["digest"], ceiling) do
      {:ok, %{"bytes" => bytes}} -> {:ok, bytes}
      :not_found -> {:error, :artifact_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_identity({module, config}, credential_ref) do
    try do
      case module.resolve(credential_ref, config) do
        {:ok, %{certificate: certificate, private_key: private_key}}
        when is_binary(certificate) ->
          {:ok, %{certificate: certificate, private_key: private_key}}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        _ ->
          {:error, :credential_broker_contract_violation}
      end
    rescue
      _ -> {:error, :credential_broker_failure}
    catch
      _, _ -> {:error, :credential_broker_failure}
    end
  end

  defp binding_config(options) do
    HTTP.config(
      client: Keyword.get(options, :http_client, {HTTPClient, %{}}),
      max_request_bytes: @control_bytes,
      max_response_bytes: @control_bytes,
      max_event_bytes: @control_bytes,
      max_header_count: 64,
      max_header_bytes: 64 * 8 * 1024,
      max_uri_bytes: 1_024
    )
  end

  defp sync_context(request_id) when is_binary(request_id) and byte_size(request_id) in 1..64 do
    Context.new(
      request_id: request_id,
      deadline: System.monotonic_time(:millisecond) + @direct_timeout_ms
    )
  end

  defp sync_context(_), do: {:error, :invalid_request_id}

  defp synchronize(
         library,
         frame,
         intent,
         td,
         artifact,
         credential,
         config,
         context,
         options,
         attempt_id
       ) do
    synchronizer = Keyword.get(options, :synchronizer, DirectSync)

    case synchronizer.sync(td, artifact, credential, config, context) do
      {:ok, %{outcome: outcome}} when outcome in [:displayed, :pending] ->
        finish(library, frame, intent, artifact, context, outcome, attempt_id)

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :direct_sync_contract_violation}
    end
  rescue
    _ -> {:error, :direct_sync_failure}
  catch
    _, _ -> {:error, :direct_sync_failure}
  end

  defp finish(library, frame, intent, artifact, context, outcome, attempt_id) do
    case Library.finish_direct_delivery(
           library,
           frame["frame_id"],
           intent["revision"],
           context.request_id,
           artifact.digest,
           outcome,
           attempt_id
         ) do
      :ok -> {:ok, :displayed}
      {:ok, :pending} -> {:ok, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_attempt(library, frame_id, request_id, mode, action) do
    attempt_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    with :ok <-
           Library.record_direct_attempt(
             library,
             frame_id,
             request_id,
             attempt_id,
             mode,
             :started
           ) do
      result = safe_attempt_action(action, attempt_id)
      outcome = attempt_outcome(result)
      record_attempt_result(library, frame_id, request_id, attempt_id, mode, outcome)

      :telemetry.execute(
        [:frameshift, :delivery, :attempt],
        %{count: 1},
        %{mode: mode, outcome: outcome}
      )

      Logger.info("direct delivery attempt completed",
        frameshift_event: :delivery_attempt,
        frameshift_outcome: outcome,
        request_id: request_id,
        attempt_id: attempt_id
      )

      result
    end
  end

  defp safe_attempt_action(action, attempt_id) do
    action.(attempt_id)
  rescue
    _ -> {:error, :direct_sync_failure}
  catch
    _, _ -> {:error, :direct_sync_failure}
  end

  defp attempt_outcome({:ok, :displayed}), do: :displayed
  defp attempt_outcome({:ok, :pending}), do: :pending

  defp attempt_outcome({:error, reason})
       when reason in [
              :timeout,
              :transport_failure,
              :direct_sync_failure,
              :direct_sync_contract_violation
            ],
       do: :unknown

  defp attempt_outcome({:error, {:database, _}}), do: :unknown
  defp attempt_outcome({:error, {:transport, _}}), do: :unknown

  defp attempt_outcome(_), do: :failed

  defp record_attempt_result(library, frame_id, request_id, attempt_id, mode, outcome) do
    case Library.record_direct_attempt(library, frame_id, request_id, attempt_id, mode, outcome) do
      :ok ->
        :ok

      {:error, _} ->
        Logger.warning("direct attempt audit unavailable", frameshift_event: :runtime)
    end
  catch
    :exit, _ -> Logger.warning("direct attempt audit unavailable", frameshift_event: :runtime)
  end
end
