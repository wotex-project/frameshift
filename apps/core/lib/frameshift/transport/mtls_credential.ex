defmodule Frameshift.Transport.MTLSCredential do
  @moduledoc """
  Scopes transient TLS identity material to one exact frame HTTPS origin.

  `new/4` validates the origin syntax, lowercase SHA-256 server pin, bounded client
  certificate bytes and supported OTP key representation. It normalizes host and
  port and retains the binary SPKI digest. Origins cannot contain userinfo, query,
  fragment or an application path; malformed input returns a typed error.
  URI reconstruction preserves brackets around IPv6 literals and suppresses the
  default HTTPS port while keeping a selected nondefault port. The unbracketed
  host remains separate for resolution and exact transport audience checks.

  ## Lifetime and inspection

  Resolve the certificate/key or signer immediately before an exchange through
  `Frameshift.Transport.CredentialResolver`. The credential is transient and must
  not be stored in recipes, TDs, command receipts or ordinary UI results.
  Its Inspect implementation exposes origin and server pin while omitting both
  client certificate and private key.

  Construction admits structure only; TLS still proves key possession and the
  transport checks the request's exact audience and destination policy. Matching
  a credential origin does not grant physical device or display authority.
  """

  @fingerprint_pattern ~r/^sha256:([0-9a-f]{64})$/
  @maximum_certificate_bytes 65_536

  @enforce_keys [
    :origin,
    :host,
    :port,
    :server_spki_sha256,
    :client_certificate,
    :client_private_key
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          origin: String.t(),
          host: String.t(),
          port: :inet.port_number(),
          server_spki_sha256: binary(),
          client_certificate: binary(),
          client_private_key: term()
        }

  @spec new(String.t(), String.t(), binary(), term()) :: {:ok, t()} | {:error, atom()}
  def new(origin, fingerprint, certificate, private_key)
      when is_binary(origin) and is_binary(fingerprint) and is_binary(certificate) do
    with {:ok, host, port, normalized_origin} <- parse_origin(origin),
         {:ok, pin} <- parse_fingerprint(fingerprint),
         :ok <- validate_certificate(certificate),
         :ok <- validate_private_key(private_key) do
      {:ok,
       %__MODULE__{
         origin: normalized_origin,
         host: host,
         port: port,
         server_spki_sha256: pin,
         client_certificate: certificate,
         client_private_key: private_key
       }}
    end
  end

  def new(_, _, _, _),
    do: {:error, :invalid_mtls_credential}

  defp parse_origin(origin) do
    with {:ok, uri} <- URI.new(origin),
         true <- uri.scheme == "https",
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, "", "/"],
         port when port in 1..65_535 <- uri.port || 443 do
      host = String.downcase(uri.host)
      normalized_origin = URI.to_string(%URI{scheme: "https", host: host, port: port})
      {:ok, host, port, normalized_origin}
    else
      _ -> {:error, :invalid_credential_origin}
    end
  end

  defp parse_fingerprint(fingerprint) do
    case Regex.run(@fingerprint_pattern, fingerprint, capture: :all_but_first) do
      [hex] ->
        case Base.decode16(hex, case: :lower) do
          {:ok, pin} -> {:ok, pin}
          :error -> {:error, :invalid_server_fingerprint}
        end

      _ ->
        {:error, :invalid_server_fingerprint}
    end
  end

  defp validate_certificate(certificate)
       when byte_size(certificate) in 1..@maximum_certificate_bytes,
       do: :ok

  defp validate_certificate(_), do: {:error, :invalid_client_certificate}

  defp validate_private_key({_, _}), do: :ok

  defp validate_private_key(%{algorithm: _, sign_fun: sign_fun})
       when is_function(sign_fun, 3),
       do: :ok

  defp validate_private_key(%{algorithm: _, engine: _, key_id: _}), do: :ok
  defp validate_private_key(_), do: {:error, :invalid_client_private_key}
end

defimpl Inspect, for: Frameshift.Transport.MTLSCredential do
  @moduledoc """
  Formats ephemeral TLS credentials without certificate or private-key material.

  The Inspect implementation emits only the normalized origin, hexadecimal server
  SPKI pin and a fixed redaction marker. It never traverses the signer/key handle
  or client certificate, so ordinary inspection cannot serialize those fields
  into an exception report or local log.

  ## Redaction scope

  This implementation belongs to `Frameshift.Transport.MTLSCredential` and changes
  presentation only. It does not encrypt memory, sanitize manually constructed
  maps or authorize a request. Callers must still keep the original credential
  transient and exclude it from persistent recipes, receipts and UI payloads.
  """

  import Inspect.Algebra

  @spec inspect(Frameshift.Transport.MTLSCredential.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(credential, opts) do
    concat([
      "#Frameshift.Transport.MTLSCredential<origin=",
      to_doc(credential.origin, opts),
      " server_spki_sha256=",
      to_doc(Base.encode16(credential.server_spki_sha256, case: :lower), opts),
      " credentials=redacted>"
    ])
  end
end
