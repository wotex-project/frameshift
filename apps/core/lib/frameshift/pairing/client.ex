defmodule Frameshift.Pairing.Client do
  @moduledoc """
  Performs the fixed pre-pair exchange with the physically pinned HTTPS peer.

  `pair/4` accepts the parsed bootstrap, ephemeral host credential, request ID
  and explicit transport options. It uses the reference commissioning path
  outside private TD Forms, with local-address admission, mutual TLS, a bounded
  deadline/body and server key pin checked before sending the secret.

  ## Receipt scope

  The response must bind the physical device ID and presented host certificate.
  A successful exchange establishes the returned commissioning receipt, not a
  stored host frame record. `Frameshift.Pairing.Admission` subsequently fetches
  the authenticated matching TD and joins it to durable native custody.

  A network failure may leave pairing outcome uncertain. Recovery observes the
  authenticated TD rather than resending the consumed secret or substituting a
  new device identifier. Ordinary advertised interactions stay separate from
  this physical-window protocol.
  """

  alias Frameshift.Pairing.Bootstrap
  alias Frameshift.Protocol.Schema
  alias Frameshift.Transport.{HTTPClient, MTLSCredential}
  alias Wotex.Binding.HTTP.{Headers, Request, Response}

  @path "/.well-known/frameshift/pair"
  @timeout_ms 10_000
  @maximum_response_bytes 2_048
  @request_id_pattern ~r/^[A-Za-z0-9._~-]{1,128}$/

  @type receipt :: %{
          device_id: String.t(),
          host_certificate_fingerprint: String.t(),
          request_id: String.t()
        }

  @doc "Pairs over a pinned pre-pair origin using an ephemeral client TLS identity."
  @spec pair(Bootstrap.t(), MTLSCredential.t(), String.t(), keyword()) ::
          {:ok, receipt()} | {:error, atom()}
  def pair(bootstrap, credential, request_id, options \\ [])

  def pair(%Bootstrap{} = bootstrap, %MTLSCredential{} = credential, request_id, options) do
    transport = Keyword.get(options, :transport, &default_transport/2)

    with :ok <- validate_bootstrap(bootstrap),
         :ok <- validate_request_id(request_id),
         :ok <- validate_pin(bootstrap, credential),
         {:ok, body} <- request_body(bootstrap, request_id),
         {:ok, request} <- request(credential.origin, request_id, body),
         {:ok, response} <- transport.(request, credential),
         {:ok, receipt} <- receipt(response, bootstrap, credential, request_id) do
      {:ok, receipt}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :pairing_transport_failure}
    end
  rescue
    _ -> {:error, :pairing_transport_failure}
  catch
    _, _ -> {:error, :pairing_transport_failure}
  end

  def pair(_, _, _, _),
    do: {:error, :invalid_pairing_request}

  defp validate_bootstrap(%Bootstrap{device_id: device_id, secret: secret})
       when is_binary(device_id) and byte_size(device_id) in 16..128 and is_binary(secret) and
              byte_size(secret) in 16..64,
       do: :ok

  defp validate_bootstrap(_), do: {:error, :invalid_pairing_request}

  defp validate_request_id(request_id) when is_binary(request_id) do
    if Regex.match?(@request_id_pattern, request_id),
      do: :ok,
      else: {:error, :invalid_pairing_request}
  end

  defp validate_request_id(_), do: {:error, :invalid_pairing_request}

  defp validate_pin(bootstrap, credential) do
    pin = "sha256:" <> Base.encode16(credential.server_spki_sha256, case: :lower)
    if pin == bootstrap.server_spki, do: :ok, else: {:error, :peer_identity_mismatch}
  end

  defp request_body(bootstrap, request_id) do
    RFC8785.encode(%{
      "version" => 1,
      "requestId" => request_id,
      "deviceId" => bootstrap.device_id,
      "secret" => Base.url_encode64(bootstrap.secret, padding: false)
    })
  end

  defp request(origin, request_id, body) do
    case Request.new(
           "POST",
           origin <> @path,
           [{"content-type", "application/json"}, {"accept", "application/json"}],
           body,
           request_id: request_id,
           deadline: System.monotonic_time(:millisecond) + @timeout_ms,
           operation: :invokeaction,
           media_type: "application/json",
           stream?: false,
           max_response_bytes: @maximum_response_bytes,
           max_event_bytes: @maximum_response_bytes,
           max_header_count: 16,
           max_header_bytes: 4_096,
           max_uri_bytes: 1_024
         ) do
      {:ok, request} -> {:ok, request}
      {:error, _} -> {:error, :invalid_pairing_request}
    end
  end

  defp default_transport(request, credential), do: HTTPClient.request(request, credential, %{})

  defp receipt(%Response{} = response, bootstrap, credential, request_id) do
    cond do
      Response.status(response) in [200, 201] and
          Headers.get(Response.headers(response), "content-type") != "application/json" ->
        {:error, :invalid_pairing_response}

      Response.status(response) in [200, 201] ->
        with {:ok, document} <-
               Wotex.JSON.decode(Response.body(response),
                 max_bytes: @maximum_response_bytes,
                 max_depth: 2,
                 max_nodes: 8,
                 max_string_bytes: 512,
                 max_collection_size: 4
               ),
             :ok <- Schema.validate("pairing-response", document),
             ^request_id <- document["requestId"],
             device_id when device_id == bootstrap.device_id <- document["deviceId"],
             expected <-
               "sha256:" <>
                 Base.encode16(:crypto.hash(:sha256, credential.client_certificate), case: :lower),
             ^expected <- document["hostCertificateFingerprint"] do
          {:ok,
           %{
             device_id: bootstrap.device_id,
             host_certificate_fingerprint: expected,
             request_id: request_id
           }}
        else
          _ -> {:error, :invalid_pairing_response}
        end

      true ->
        {:error, :pairing_rejected}
    end
  end

  defp receipt(_, _, _, _),
    do: {:error, :invalid_pairing_response}
end
