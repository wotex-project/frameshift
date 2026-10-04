defmodule Frameshift.Pairing.Admission do
  @moduledoc """
  Joins a transient physical pairing exchange to durable native frame custody.

  `pair/6` parses the physical bootstrap, matches discovery's device ID, resolves
  the explicit host identity and performs a pinned commissioning exchange. It
  then retrieves and validates the authenticated TD for that same device before
  admitting a paired record through `Frameshift.Library`.

  ## Secret and recovery boundaries

  The QR secret and bootstrap source remain transient; the writer receives only
  the authenticated TD, opaque credential reference and server pin. A discovery
  origin is a candidate endpoint, never permission to send a secret before the
  physical key pin matches.

  `recover/5` reconciles an uncertain pairing by reading the authenticated TD
  without reposting the one-time secret. Invalid discovery, identity, TD or
  exchange evidence refuses durable admission. Successful admission refreshes
  the pull outbox service; it does not imply hardware key-storage qualification
  or authorize a different frame with similar capabilities.
  """

  alias Frameshift.Library
  alias Frameshift.Outbox.Service
  alias Frameshift.Pairing.{Bootstrap, Client}
  alias Frameshift.Protocol.Thing
  alias Frameshift.Transport.{HTTPClient, MTLSCredential}
  alias Wotex.Binding.HTTP.{Headers, Request, Response}
  alias Wotex.ThingDescription

  @thing_path "/.well-known/wot"
  @maximum_thing_bytes 262_144
  @timeout_ms 10_000

  @doc "Pairs one discovered device and admits only its authenticated matching TD."
  @spec pair(binary(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def pair(bootstrap_source, discovered_id, origin, credential_ref, request_id, options \\ []) do
    resolver = Keyword.get(options, :resolver)
    library = Keyword.get(options, :library, Library)
    transport_config = Keyword.get(options, :transport_config, %{})

    pairer =
      Keyword.get(options, :pairer, fn bootstrap, credential, id ->
        Client.pair(bootstrap, credential, id,
          transport: fn request, resolved ->
            HTTPClient.request(request, resolved, transport_config)
          end
        )
      end)

    fetcher =
      Keyword.get(options, :fetcher, fn credential, path ->
        fetch_thing(credential, path, transport_config)
      end)

    with {:ok, bootstrap} <- Bootstrap.parse(bootstrap_source),
         :ok <- match_discovery(bootstrap, discovered_id),
         :ok <- validate_reference(credential_ref),
         :ok <- require_unpaired(library, bootstrap),
         {:ok, identity} <- resolve_identity(resolver, credential_ref),
         {:ok, credential} <-
           MTLSCredential.new(
             origin,
             bootstrap.server_spki,
             identity.certificate,
             identity.private_key
           ) do
      exchange(bootstrap, credential, credential_ref, request_id, library, pairer, fetcher)
    else
      _ -> {:error, :pairing_preflight_failed}
    end
  end

  @doc "Reconciles an uncertain pair by reading only the authenticated TD, without reposting its secret."
  @spec recover(binary(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def recover(bootstrap_source, discovered_id, origin, credential_ref, options \\ []) do
    resolver = Keyword.get(options, :resolver)
    library = Keyword.get(options, :library, Library)
    transport_config = Keyword.get(options, :transport_config, %{})

    fetcher =
      Keyword.get(options, :fetcher, fn credential, path ->
        fetch_thing(credential, path, transport_config)
      end)

    with {:ok, bootstrap} <- Bootstrap.parse(bootstrap_source),
         :ok <- match_discovery(bootstrap, discovered_id),
         :ok <- validate_reference(credential_ref),
         :ok <- require_unpaired(library, bootstrap),
         {:ok, identity} <- resolve_identity(resolver, credential_ref),
         {:ok, credential} <-
           MTLSCredential.new(
             origin,
             bootstrap.server_spki,
             identity.certificate,
             identity.private_key
           ) do
      admit_after_pair(bootstrap, credential, credential_ref, library, fetcher)
    else
      _ -> {:error, :pairing_preflight_failed}
    end
  end

  defp match_discovery(%Bootstrap{device_id: device_id}, device_id), do: :ok
  defp match_discovery(_, _), do: {:error, :discovery_identity_mismatch}

  defp validate_reference("keychain:" <> encoded) when byte_size(encoded) in 1..1_015,
    do: :ok

  defp validate_reference(_), do: {:error, :invalid_credential_reference}

  defp require_unpaired(library, bootstrap) do
    case {Library.get_paired_frame(library, bootstrap.device_id),
          Library.get_paired_frame_by_spki(library, bootstrap.server_spki)} do
      {:not_found, :not_found} -> :ok
      _ -> {:error, :already_paired}
    end
  end

  defp resolve_identity({module, config}, reference) when is_atom(module) and is_map(config) do
    case module.resolve(reference, config) do
      {:ok, %{certificate: certificate, private_key: private_key}}
      when is_binary(certificate) ->
        {:ok, %{certificate: certificate, private_key: private_key}}

      _ ->
        {:error, :credential_unavailable}
    end
  end

  defp resolve_identity(_, _), do: {:error, :credential_unavailable}

  defp exchange(bootstrap, credential, reference, request_id, library, pairer, fetcher) do
    case pairer.(bootstrap, credential, request_id) do
      {:ok, %{device_id: device_id}} when device_id == bootstrap.device_id ->
        admit_after_pair(bootstrap, credential, reference, library, fetcher)

      {:error, :pairing_rejected} ->
        {:error, :pairing_rejected}

      _ ->
        {:error, :pairing_outcome_unknown}
    end
  end

  defp admit_after_pair(bootstrap, credential, reference, library, fetcher) do
    with {:ok, td_source} <- fetcher.(credential, @thing_path),
         :ok <- Bootstrap.verify_thing_description(bootstrap, td_source),
         :ok <- verify_thing_origin(td_source, credential),
         {:ok, frame} <-
           Library.register_paired_frame(library, td_source, reference, bootstrap.server_spki) do
      Service.refresh()
      {:ok, %{"frameId" => frame["frame_id"]}}
    else
      _ -> {:error, :pairing_incomplete}
    end
  end

  defp verify_thing_origin(source, credential) do
    with {:ok, thing} <- Thing.parse_frame(source),
         %{"base" => base} when is_binary(base) <- ThingDescription.to_map(thing),
         {:ok, uri} <- URI.new(base),
         true <- uri.scheme == "https" and String.downcase(uri.host || "") == credential.host,
         true <- (uri.port || 443) == credential.port,
         true <- uri.path in [nil, "", "/"],
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      _ -> {:error, :thing_origin_mismatch}
    end
  end

  defp fetch_thing(credential, path, transport_config) do
    with {:ok, request} <-
           Request.new(
             "GET",
             credential.origin <> path,
             [{"accept", "application/json"}],
             <<>>,
             request_id: "pairing-thing",
             deadline: System.monotonic_time(:millisecond) + @timeout_ms,
             operation: :readproperty,
             media_type: "application/json",
             stream?: false,
             max_response_bytes: @maximum_thing_bytes,
             max_event_bytes: @maximum_thing_bytes,
             max_header_count: 32,
             max_header_bytes: 8_192,
             max_uri_bytes: 1_024
           ),
         {:ok, response} <- HTTPClient.request(request, credential, transport_config),
         200 <- Response.status(response),
         "application/json" <- Headers.get(Response.headers(response), "content-type"),
         body when is_binary(body) and byte_size(body) in 1..@maximum_thing_bytes <-
           Response.body(response) do
      {:ok, body}
    else
      _ -> {:error, :thing_unavailable}
    end
  end
end
