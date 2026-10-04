Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

defmodule Frameshift.LinuxCredentialFixture do
  @moduledoc false

  alias Frameshift.Digest
  alias Frameshift.Transport.{HTTPClient, MTLSCredential, ProtectedFile, SPKIPin}
  alias Wotex.Binding.HTTP.{Request, Response}

  @spec run(String.t()) :: :ok
  def run(wrong_owner) do
    root = "/tmp/fs-linux-key-#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    try do
      pki =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: [key: {:rsa, 2048, 65_537}],
            intermediates: [],
            peer: [key: {:rsa, 2048, 65_537}]
          },
          client_chain: %{
            root: [key: {:rsa, 2048, 65_537}],
            intermediates: [],
            peer: [key: {:rsa, 2048, 65_537}]
          }
        })

      certificate = Keyword.fetch!(pki.client_config, :cert)
      {type, der} = Keyword.fetch!(pki.client_config, :key)
      hex = Digest.hex!(Digest.sha256(certificate))
      reference = "linux-pem-v1:" <> hex
      path = Path.join(root, hex <> ".pem")

      pem =
        :public_key.pem_encode([
          {:Certificate, certificate, :not_encrypted},
          {type, der, :not_encrypted}
        ])

      File.write!(path, pem)
      File.chmod!(path, 0o400)
      File.touch!(path, 1)
      {:ok, config} = ProtectedFile.configure(root)
      {:ok, identity} = ProtectedFile.resolve(reference, config)
      true = identity.certificate == certificate
      tls_join(pki, identity, :inet)
      tls_join(pki, identity, :inet6)
      refusal_checks(root, path, pem, reference, config, wrong_owner)
      IO.puts("protected-file-pinned-tls-passed")
    after
      File.rm_rf!(root)
    end
  end

  defp tls_join(pki, identity, family) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    address = if family == :inet6, do: {0, 0, 0, 0, 0, 0, 0, 1}, else: {127, 0, 0, 1}

    {:ok, listener} =
      :ssl.listen(
        0,
        [family | Keyword.put(pki.server_config, :ip, address)] ++
          [
            active: false,
            mode: :binary,
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            versions: [:"tlsv1.3"]
          ]
      )

    try do
      {:ok, {_, port}} = :ssl.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, transport} = :ssl.transport_accept(listener, 5_000)
          {:ok, socket} = :ssl.handshake(transport, 5_000)

          try do
            {:ok, certificate} = :ssl.peercert(socket)
            true = certificate == identity.certificate
            {:ok, request} = :ssl.recv(socket, 0, 5_000)
            true = String.contains?(request, "GET /state HTTP/1.1")
            :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n42")
          after
            :ssl.close(socket)
          end
        end)

      {:ok, pin} = SPKIPin.fingerprint_der(Keyword.fetch!(pki.server_config, :cert))
      origin = if family == :inet6, do: "https://[::1]:#{port}", else: "https://127.0.0.1:#{port}"

      {:ok, credential} =
        MTLSCredential.new(origin, pin, identity.certificate, identity.private_key)

      {:ok, request} =
        Request.new("GET", origin <> "/state", [], <<>>,
          request_id: "protected-file-tls-fixture",
          operation: :readproperty,
          deadline: System.monotonic_time(:millisecond) + 5_000,
          media_type: "application/json",
          stream?: false,
          max_response_bytes: 1_024,
          max_event_bytes: 1_024,
          max_header_count: 16,
          max_header_bytes: 4_096,
          max_uri_bytes: 1_024
        )

      {:ok, response} = HTTPClient.request(request, credential, %{allow_loopback: true})
      200 = Response.status(response)
      "42" = Response.body(response)
      :ok = Task.await(server, 6_000)
    after
      :ssl.close(listener)
    end
  end

  defp refusal_checks(root, path, pem, reference, config, wrong_owner) do
    File.chmod!(path, 0o640)
    {:error, :credential_custody_unavailable} = ProtectedFile.resolve(reference, config)
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    0o640 = Bitwise.band(mode, 0o7777)
    File.chmod!(path, 0o600)
    {:ok, _} = ProtectedFile.resolve(reference, config)
    File.chmod!(root, 0o750)
    {:error, :credential_custody_unavailable} = ProtectedFile.configure(root)
    File.chmod!(root, 0o700)
    File.rm!(path)
    {:error, :credential_custody_unavailable} = ProtectedFile.resolve(reference, config)
    target = Path.join(root, "target.pem")
    File.write!(target, pem)
    File.chmod!(target, 0o600)
    {:ok, before} = File.lstat(target)
    File.ln_s!(target, path)
    {:error, :credential_custody_unavailable} = ProtectedFile.resolve(reference, config)
    {:ok, ^before} = File.lstat(target)
    File.rm!(path)
    File.write!(path, String.duplicate("x", 131_073))
    File.chmod!(path, 0o600)
    {:error, :credential_custody_unavailable} = ProtectedFile.resolve(reference, config)
    File.write!(path, "malformed")
    {:error, :invalid_protected_credential} = ProtectedFile.resolve(reference, config)
    {:ok, wrong_config} = ProtectedFile.configure(wrong_owner)

    {:error, :credential_custody_unavailable} =
      ProtectedFile.resolve("linux-pem-v1:" <> String.duplicate("f", 64), wrong_config)

    link = root <> "-link"
    File.ln_s!(root, link)

    try do
      {:error, :credential_custody_unavailable} = ProtectedFile.configure(link)

      {:error, :credential_custody_unavailable} =
        ProtectedFile.resolve(reference, %{config | uid: 0})
    after
      File.rm!(link)
    end
  end
end

[wrong_owner] = System.argv()
Frameshift.LinuxCredentialFixture.run(wrong_owner)
