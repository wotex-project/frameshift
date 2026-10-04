defmodule Frameshift.Transport.KeychainBroker do
  @moduledoc """
  Obtains a public certificate and transient signer from the native menu process.

  `resolve/2` receives an opaque persistent identity reference plus an explicit
  Unix-socket path and bootstrap token. A bounded local broker exchange returns
  the certificate and an OTP three-argument signing callback. Signing requests
  send only the bounded handshake material required by the broker protocol.

  ## Key custody and failures

  The private key stays in Keychain; this module never extracts it into a file or
  persists a copy in SQLite. The launch token authenticates the local broker
  exchange and is excluded from ordinary command/log data. Reference, framing,
  timeout or broker availability failures return errors before usable credential
  material is provided.

  `Frameshift.Transport.CredentialResolver` defines the higher-level contract;
  `Frameshift.Transport.HTTPClient` applies origin and server-pin checks later.
  A returned signer establishes access to that host identity, not frame pairing
  or authorization for another advertised origin.
  """

  @behaviour Frameshift.Transport.CredentialResolver

  @maximum_packet_bytes 128 * 1024
  @maximum_certificate_bytes 65_536
  @timeout_ms 5_000

  @impl true
  @doc "Resolves one persistent identity reference into a public certificate and signer."
  @spec resolve(String.t(), map()) ::
          {:ok, Frameshift.Transport.CredentialResolver.identity()} | {:error, atom()}
  def resolve(reference, %{socket_path: path, token: token} = config)
      when is_binary(reference) and byte_size(reference) in 1..1_024 and is_binary(path) and
             is_binary(token) do
    with {:ok, %{"certificate" => encoded, "algorithm" => algorithm}} <-
           exchange(config, %{"operation" => "resolve", "reference" => reference}),
         true <- algorithm in ["ecdsa", "rsa"],
         true <- is_binary(encoded),
         {:ok, certificate} <- Base.decode64(encoded),
         true <- byte_size(certificate) in 1..@maximum_certificate_bytes do
      signing_algorithm = if algorithm == "ecdsa", do: :ecdsa, else: :rsa

      signer = fn message, digest_type, options ->
        sign!(config, reference, algorithm, message, digest_type, options)
      end

      {:ok,
       %{certificate: certificate, private_key: %{algorithm: signing_algorithm, sign_fun: signer}}}
    else
      false -> {:error, :credential_broker_contract_violation}
      :error -> {:error, :credential_broker_contract_violation}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :credential_broker_contract_violation}
    end
  end

  def resolve(_, _), do: {:error, :credential_broker_unavailable}

  defp sign!(config, reference, algorithm, message, digest_type, options) do
    with {:ok, digest} <- digest_input(message, digest_type),
         {:ok, scheme} <- signature_scheme(algorithm, digest_type, options),
         {:ok, %{"signature" => encoded}} <-
           exchange(config, %{
             "operation" => "sign",
             "reference" => reference,
             "scheme" => scheme,
             "digest" => Base.encode64(digest)
           }),
         {:ok, signature} <- Base.decode64(encoded),
         true <- byte_size(signature) in 1..4_096 do
      signature
    else
      _ -> raise "Keychain signing failed"
    end
  end

  defp digest_input({:digest, digest}, algorithm) when is_binary(digest) do
    if byte_size(digest) == digest_size(algorithm),
      do: {:ok, digest},
      else: {:error, :invalid_digest}
  end

  defp digest_input(message, algorithm)
       when is_binary(message) and byte_size(message) <= 65_536 do
    if digest_size(algorithm) > 0,
      do: {:ok, :crypto.hash(algorithm, message)},
      else: {:error, :unsupported_digest}
  end

  defp digest_input(_, _), do: {:error, :invalid_digest}

  defp digest_size(:sha256), do: 32
  defp digest_size(:sha384), do: 48
  defp digest_size(:sha512), do: 64
  defp digest_size(_), do: 0

  defp signature_scheme("ecdsa", digest_type, []) when digest_type in [:sha256, :sha384, :sha512],
    do: {:ok, "ecdsa-#{digest_type}"}

  defp signature_scheme("rsa", digest_type, options)
       when digest_type in [:sha256, :sha384, :sha512] and is_list(options) do
    padding = Keyword.get(options, :rsa_padding, :rsa_pkcs1_padding)

    case padding do
      :rsa_pkcs1_padding -> {:ok, "rsa-pkcs1-#{digest_type}"}
      :rsa_pkcs1_pss_padding -> validate_pss_options(digest_type, options)
      _ -> {:error, :unsupported_signature_scheme}
    end
  end

  defp signature_scheme(_, _, _),
    do: {:error, :unsupported_signature_scheme}

  defp validate_pss_options(digest_type, options) do
    if Keyword.get(options, :rsa_pss_saltlen, digest_size(digest_type)) ==
         digest_size(digest_type),
       do: {:ok, "rsa-pss-#{digest_type}"},
       else: {:error, :unsupported_signature_scheme}
  end

  defp exchange(%{socket_path: path, token: token} = config, payload) do
    transport = Map.get(config, :transport, &socket_exchange/2)

    with {:ok, response} <- transport.(path, Map.put(payload, "auth", token)),
         %{"ok" => true} <- response do
      {:ok, response}
    else
      %{"ok" => false} -> {:error, :credential_broker_failure}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :credential_broker_contract_violation}
    end
  end

  defp socket_exchange(path, payload) do
    with {:ok, bytes} <- RFC8785.encode(payload),
         true <- byte_size(bytes) <= @maximum_packet_bytes,
         {:ok, socket} <-
           :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false], @timeout_ms) do
      try do
        with :ok <- :gen_tcp.send(socket, bytes),
             {:ok, response} <- :gen_tcp.recv(socket, 0, @timeout_ms),
             true <- byte_size(response) <= @maximum_packet_bytes,
             {:ok, decoded} <-
               Wotex.JSON.decode(response,
                 max_bytes: @maximum_packet_bytes,
                 max_depth: 4,
                 max_nodes: 16,
                 max_string_bytes: @maximum_packet_bytes,
                 max_collection_size: 8
               ) do
          {:ok, decoded}
        else
          _ -> {:error, :credential_broker_failure}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:error, :credential_broker_unavailable}
    end
  end
end
