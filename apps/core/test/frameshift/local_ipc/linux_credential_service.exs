Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

defmodule Frameshift.LinuxCredentialFixture do
  @moduledoc false

  alias Frameshift.Digest

  alias Frameshift.Transport.{
    HTTPClient,
    MTLSCredential,
    ProtectedFile,
    ProtectedFileInstaller,
    SPKIPin
  }

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

      {:ok, config} = ProtectedFile.configure(root)
      {:ok, ^reference, :created} = ProtectedFileInstaller.install(pem, config)
      true = File.read!(path) == pem
      {:ok, %{mode: mode}} = File.lstat(path)
      true = Bitwise.band(mode, 0o7777) == 0o400
      File.touch!(path, 1)
      {:ok, before} = File.lstat(path)
      {:ok, ^reference, :existing} = ProtectedFileInstaller.install("\n" <> pem, config)
      {:ok, after_replay} = File.lstat(path)
      true = Map.delete(before, :atime) == Map.delete(after_replay, :atime)
      {:ok, identity} = ProtectedFile.resolve(reference, config)
      true = identity.certificate == certificate
      tls_join(pki, identity, :inet)
      tls_join(pki, identity, :inet6)
      pairing_directory_join(root)
      installation_checks(root, path, pem, reference, config)
      refusal_checks(root, path, pem, reference, config, wrong_owner)
      IO.puts("protected-file-pinned-tls-passed")
    after
      File.rm_rf!(root)
    end
  end

  defp installation_checks(root, path, pem, reference, config) do
    concurrent = Path.join(root, "concurrent")
    File.mkdir!(concurrent)
    File.chmod!(concurrent, 0o700)
    {:ok, parallel_config} = ProtectedFile.configure(concurrent)

    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> ProtectedFileInstaller.install(pem, parallel_config) end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    1 = Enum.count(results, &(&1 == {:ok, reference, :created}))

    true =
      Enum.all?(
        results,
        &(&1 in [
            {:ok, reference, :created},
            {:ok, reference, :existing},
            {:error, :credential_conflict}
          ])
      )

    {:ok, _} = ProtectedFile.resolve(reference, parallel_config)
    [name] = File.ls!(concurrent)
    true = String.ends_with?(name, ".pem") and not String.starts_with?(name, ".")

    input = Path.join(root, "stdin.pem")
    File.write!(input, pem)
    File.chmod!(input, 0o600)
    {:ok, %{uid: uid}} = ProtectedFile.configure(root)
    cli = Path.join(root, "cli")
    File.mkdir!(cli)
    File.chmod!(cli, 0o700)

    code =
      "Code.prepend_paths(Path.wildcard(\"/src/_build/test/lib/*/ebin\")); Frameshift.IdentityCLI.main(System.argv())"

    env = [
      {"FRAMESHIFT_SERVICE_UID", Integer.to_string(uid)},
      {"FRAMESHIFT_CREDENTIAL_DIRECTORY", cli},
      {"FRAMESHIFT_IDENTITY_FIXTURE", input}
    ]

    {output, 0} = identity_process(code, env)

    %{"version" => 1, "credentialRef" => ^reference, "status" => "created"} =
      JSON.decode!(output)

    false = String.contains?(output, ["PRIVATE KEY", pem, root])
    [name] = File.ls!(cli)
    cli_path = Path.join(cli, name)
    File.touch!(cli_path, 1)
    previous = File.stat!(cli_path)
    {output, 0} = identity_process(code, env)

    %{"version" => 1, "credentialRef" => ^reference, "status" => "existing"} =
      JSON.decode!(output)

    false = String.contains?(output, ["PRIVATE KEY", pem, root])

    for {bytes, status} <- [{"invalid PEM", 2}, {"", 64}, {:binary.copy(<<0>>, 131_073), 64}] do
      File.write!(input, bytes)
      {output, ^status} = identity_process(code, env)
      false = String.contains?(output, ["PRIVATE KEY", pem, root])
      [^name] = File.ls!(cli)
    end

    true = File.read!(cli_path) == pem
    true = Map.delete(previous, :atime) == Map.delete(File.stat!(cli_path), :atime)
    File.rm!(input)

    orphan = Path.join(root, ".identity-abandoned.pem")
    File.write!(orphan, pem)
    File.chmod!(orphan, 0o400)

    {:error, :credential_custody_unavailable} =
      ProtectedFile.resolve("linux-pem-v1:.identity-abandoned", config)

    true = File.read!(orphan) == pem
    File.chmod!(path, 0o600)
    File.write!(path, "malformed retained custody")
    File.chmod!(path, 0o400)
    {:error, :credential_conflict} = ProtectedFileInstaller.install(pem, config)
    "malformed retained custody" = File.read!(path)
    File.rm!(path)
    File.ln_s!(orphan, path)
    {:error, :credential_conflict} = ProtectedFileInstaller.install(pem, config)
    true = File.read!(orphan) == pem
    File.rm!(path)
    File.mkdir!(path)
    {:error, :credential_conflict} = ProtectedFileInstaller.install(pem, config)
    File.rmdir!(path)
    {:error, :invalid_protected_credential} = ProtectedFileInstaller.install("junk", config)
    false = File.exists?(path)
    {:ok, ^reference, :created} = ProtectedFileInstaller.install(pem, config)
    publication_fault_check(root, pem, reference, config.uid)
    full_disk_check(root, pem)
    IO.puts("protected-identity-import-passed")
  end

  defp identity_process(code, env) do
    System.cmd(
      "/bin/sh",
      [
        "-c",
        ~s(exec elixir "$@" < "$FRAMESHIFT_IDENTITY_FIXTURE"),
        "--",
        "-e",
        code,
        "--",
        "import"
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp publication_fault_check(root, pem, reference, uid) do
    directory = Path.join(root, "post-link-fault")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, config} = ProtectedFile.configure(directory)
    "linux-pem-v1:" <> hex = reference
    target = Path.join(directory, hex <> ".pem")
    original = Process.whereis(:file_server_2)
    Process.unregister(:file_server_2)

    # In this isolated VM, forward real OTP filesystem calls and change actual
    # custody after the successful hard link but before its caller can proceed.
    proxy = spawn(fn -> filesystem_proxy(original, target, directory) end)
    Process.register(proxy, :file_server_2)
    names = ~w(FRAMESHIFT_SERVICE_UID FRAMESHIFT_CREDENTIAL_DIRECTORY)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      System.put_env("FRAMESHIFT_SERVICE_UID", Integer.to_string(uid))
      System.put_env("FRAMESHIFT_CREDENTIAL_DIRECTORY", directory)
      {:ok, input} = StringIO.open(pem)
      {75, output, error} = Frameshift.IdentityCLI.run(["import"], input)
      StringIO.close(input)

      %{"version" => 1, "credentialRef" => ^reference, "status" => "unknown"} =
        JSON.decode!(output)

      true = error =~ "uncertain installation"
      false = String.contains?(output <> error, ["PRIVATE KEY", pem, root])
      true = File.read!(target) == pem
      [name] = File.ls!(directory)
      true = name == hex <> ".pem"
    after
      Process.unregister(:file_server_2)
      Process.register(original, :file_server_2)
      Process.exit(proxy, :kill)
      File.chmod!(directory, 0o700)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end

    {:ok, ^reference, :existing} = ProtectedFileInstaller.install(pem, config)
    {:ok, _} = ProtectedFile.resolve(reference, config)
  end

  defp filesystem_proxy(original, target, directory) do
    receive do
      {:"$gen_call", from, request} ->
        result = GenServer.call(original, request, 5_000)

        case {request, result} do
          {{:make_link, _, destination}, :ok} ->
            if to_string(destination) == target do
              {_, 0} = System.cmd("/bin/chmod", ["755", directory], stderr_to_stdout: true)
            end

          _ ->
            :ok
        end

        GenServer.reply(from, result)
        filesystem_proxy(original, target, directory)
    end
  end

  defp full_disk_check(root, pem) do
    directory = Path.join(root, "full")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, config} = ProtectedFile.configure(directory)
    filler = Path.join(root, "filler")
    {:ok, file} = File.open(filler, [:write, :raw, :binary, :exclusive])

    try do
      fill(file, 0)
      {:error, :credential_installation_unavailable} = ProtectedFileInstaller.install(pem, config)
      [] = File.ls!(directory)
    after
      File.close(file)
      File.rm(filler)
    end
  end

  defp fill(file, count) when count < 1_024 do
    case :file.write(file, :binary.copy(<<0>>, 65_536)) do
      :ok -> fill(file, count + 1)
      {:error, :enospc} -> :ok
    end
  end

  defp pairing_directory_join(root) do
    directory = Path.join(root, "pairing")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    {:ok, window} =
      Frameshift.Pairing.Store.load_or_create(directory, "frame-000000000001", <<1::128>>)

    paired = %{
      window
      | secret: nil,
        host_certificate_fingerprint: "sha256:" <> String.duplicate("a", 64),
        paired_request_id: "fs-fixture"
    }

    :ok = Frameshift.Pairing.Store.save(directory, paired)

    {:ok, ^paired} =
      Frameshift.Pairing.Store.load_or_create(directory, "frame-000000000001", <<1::128>>)

    IO.puts("pairing-directory-sync-passed")
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
