defmodule Frameshift.Pairing.Request do
  @moduledoc """
  Admits bounded commissioning request data separately from TLS identity.

  `parse/1` accepts only the exact versioned device ID, single-use secret and
  idempotency request ID shape within a 2 KiB body. Encoding, field and schema
  checks refuse ambiguous or malformed requests. Struct inspection exposes IDs
  but omits the secret.

  ## Applying admitted input

  `authorize/4` passes the request and the already verified peer DER to
  `Frameshift.Pairing.Window` with explicit time. JSON never supplies certificate
  identity or permission to open the physical window. A parsed request has no
  authority until the window and peer checks pass.

  The frame owner persists the resulting state before acknowledging pairing.
  Do not retain request structs in ordinary diagnostics or reuse a consumed secret
  to recover an uncertain network outcome; authenticated observation is separate.
  """

  alias Frameshift.Pairing.Window

  @maximum_bytes 2_048
  @device_id_pattern ~r/^[A-Za-z0-9._~-]{16,128}$/
  @request_id_pattern ~r/^[A-Za-z0-9._~-]{1,128}$/
  @secret_pattern ~r/^[A-Za-z0-9_-]{22,86}$/

  @derive {Inspect, only: [:request_id, :device_id]}
  @enforce_keys [:request_id, :device_id, :secret]
  defstruct @enforce_keys

  @type t :: %__MODULE__{request_id: String.t(), device_id: String.t(), secret: binary()}

  @doc "Rejects oversized, ambiguous, or non-canonical pairing request JSON."
  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_pairing_request}
  def parse(source) when is_binary(source) and byte_size(source) in 1..@maximum_bytes do
    with {:ok, document} <-
           Wotex.JSON.decode(source,
             max_bytes: @maximum_bytes,
             max_depth: 2,
             max_nodes: 8,
             max_string_bytes: 512,
             max_collection_size: 4
           ),
         %{
           "version" => 1,
           "requestId" => request_id,
           "deviceId" => device_id,
           "secret" => encoded_secret
         } <- document,
         true <- map_size(document) == 4,
         true <- is_binary(request_id) and Regex.match?(@request_id_pattern, request_id),
         true <- is_binary(device_id) and Regex.match?(@device_id_pattern, device_id),
         true <- is_binary(encoded_secret) and Regex.match?(@secret_pattern, encoded_secret),
         {:ok, secret} <- Base.url_decode64(encoded_secret, padding: false),
         true <- byte_size(secret) in 16..64,
         true <- Base.url_encode64(secret, padding: false) == encoded_secret do
      {:ok, %__MODULE__{request_id: request_id, device_id: device_id, secret: secret}}
    else
      _ -> {:error, :invalid_pairing_request}
    end
  end

  def parse(_), do: {:error, :invalid_pairing_request}

  @doc "Applies an admitted body to an already TLS-authenticated peer window."
  @spec authorize(Window.t(), t(), binary(), non_neg_integer()) ::
          {:ok, Window.t()} | {:error, atom(), Window.t()}
  def authorize(%Window{} = window, %__MODULE__{} = request, peer_der, now_ms) do
    Window.authorize(
      window,
      request.request_id,
      request.device_id,
      request.secret,
      peer_der,
      now_ms
    )
  end
end
