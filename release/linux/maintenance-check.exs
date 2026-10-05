defmodule FrameshiftUbuntuMaintenanceFixture do
  @moduledoc false

  def run do
    uid = account("-u")
    gid = account("-g")
    custody_refusal(uid, gid)
    early_lock_refusal()
    reference = identity()
    root = "/var/backups/frameshift"
    backup = root <> "/exact backup $() `literal`"
    restored = root <> "/restored candidate"

    {"backup: ok\n", 0} =
      maintenance(["backup", backup], [
        {"FRAMESHIFT_DATA_DIR", "/tmp/forged-data"},
        {"ERL_FLAGS", "invalid"}
      ])

    false = File.exists?("/tmp/forged-data")
    {"verify: ok\n", 0} = maintenance(["verify", backup])
    {_, 1} = maintenance(["backup", backup])

    for excluded <- ["credentials", "tmp", ".installed-version"] do
      false = File.exists?(Path.join(backup, excluded))
    end

    manifest = File.read!(Path.join(backup, "manifest.json"))
    {:ok, %{"objects" => [object | _]}} = Wotex.JSON.decode(manifest)
    corrupt = root <> "/corrupt"
    File.cp_r!(backup, corrupt)

    for path <- files(corrupt) do
      File.chown!(path, uid)
      File.chgrp!(path, gid)
    end

    object_path = Frameshift.ContentStore.object_path(corrupt, object["digest"])
    true = File.regular?(object_path)
    File.write!(object_path, "corrupt fixture bytes")
    {_, 1} = maintenance(["verify", corrupt])
    refused = root <> "/corrupt-refused"
    {_, 1} = maintenance(["restore", corrupt, refused])
    false = File.exists?(refused)
    {"restore: ok\n", 0} = maintenance(["restore", backup, restored])
    {_, 1} = maintenance(["restore", backup, restored])
    {"verify: ok\n", 0} = maintenance(["verify", backup])
    ^manifest = File.read!(Path.join(backup, "manifest.json"))

    for excluded <- ["credentials", "tmp", ".installed-version"] do
      false = File.exists?(Path.join(restored, excluded))
    end

    {actor, 0} = System.cmd("id", ["-u", "frame-control"])

    [_, version] =
      File.read!("/usr/lib/frameshift/core/releases/start_erl.data") |> String.split()

    release = "/usr/lib/frameshift/core/releases/" <> version

    {output, 0} =
      System.cmd(
        "runuser",
        [
          "-u",
          "frameshift",
          "--",
          release <> "/elixir",
          "--boot",
          release <> "/start_clean",
          "--boot-var",
          "RELEASE_LIB",
          "/usr/lib/frameshift/core/lib",
          "/fixtures/verify-maintenance.exs",
          restored,
          String.trim(actor),
          reference
        ],
        stderr_to_stdout: true
      )

    true =
      String.contains?(
        output,
        "Restored exact original/pixel/receipt and protected identity readback passed"
      )

    active_verification(backup, restored, uid)

    IO.puts(
      "Ubuntu packaged maintenance passed: early/live lock refusal, literal paths, isolated environment, exact backup/restore/corrupt refusal and protected stdin identity without exported keys"
    )
  end

  defp custody_refusal(uid, gid) do
    path = "/var/backups/frameshift"
    File.chmod!(path, 0o755)

    {_, 69} =
      System.cmd("/usr/lib/frameshift/provision-runtime", ["--maintenance"],
        stderr_to_stdout: true
      )

    0o755 = Bitwise.band(File.stat!(path).mode, 0o7777)
    File.chmod!(path, 0o700)
    File.rmdir!(path)
    target = "/tmp/unrelated-backup-target"
    File.mkdir!(target)
    File.write!(target <> "/sentinel", "retained")
    File.ln_s!(target, path)

    {_, 69} =
      System.cmd("/usr/lib/frameshift/provision-runtime", ["--maintenance"],
        stderr_to_stdout: true
      )

    ["sentinel"] = File.ls!(target)
    "retained" = File.read!(target <> "/sentinel")
    File.rm!(path)
    File.mkdir!(path)
    File.chown!(path, uid)
    File.chgrp!(path, gid)
    File.chmod!(path, 0o700)

    {_, 69} =
      System.cmd(
        "runuser",
        [
          "-u",
          "frame-control",
          "--",
          "/usr/bin/frameshift-maintenance",
          "backup",
          path <> "/role-refused"
        ],
        stderr_to_stdout: true
      )

    false = File.exists?(path <> "/role-refused")
  end

  defp early_lock_refusal do
    holder =
      Port.open({:spawn_executable, ~c"/usr/sbin/runuser"}, [
        :binary,
        :exit_status,
        args: [
          "-u",
          "frameshift",
          "--",
          "flock",
          "--exclusive",
          "--nonblock",
          "/var/lib/frameshift",
          "/bin/sh",
          "-c",
          "printf 'locked\\n'; IFS= read -r release"
        ]
      ])

    receive do
      {^holder, {:data, "locked\n"}} -> :ok
    after
      5_000 -> raise "directory lock holder unavailable"
    end

    false = File.exists?("/run/frameshift/control/c.sock")
    {_, 69} = maintenance(["backup", "/var/backups/frameshift/early-refused"])
    false = File.exists?("/var/backups/frameshift/early-refused")

    {_, 69} =
      System.cmd("runuser", ["-u", "frameshift", "--", "/usr/lib/frameshift/launch-service"],
        stderr_to_stdout: true
      )

    true = Port.command(holder, "release\n")
    exit_status(holder)
    {_, 0} = System.cmd("flock", ["--nonblock", "/var/lib/frameshift", "/bin/true"])
  end

  defp identity do
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
    {type, key} = Keyword.fetch!(pki.client_config, :key)

    pem =
      :public_key.pem_encode([
        {:Certificate, certificate, :not_encrypted},
        {type, key, :not_encrypted}
      ])

    directory = "/tmp/frameshift-identity-fixture"
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    input = directory <> "/key.pem"
    File.write!(input, pem)
    File.chmod!(input, 0o600)
    reference = "linux-pem-v1:" <> Frameshift.Digest.hex!(Frameshift.Digest.sha256(certificate))

    for status <- ["created", "existing"] do
      {output, 0} =
        System.cmd(
          "/bin/sh",
          [
            "-c",
            "exec runuser -u frameshift -- /usr/bin/frameshift-identity import </tmp/frameshift-identity-fixture/key.pem"
          ],
          stderr_to_stdout: true,
          env: [
            {"FRAMESHIFT_CREDENTIAL_DIRECTORY", "/tmp/forged-credentials"},
            {"FRAMESHIFT_SERVICE_UID", "0"}
          ]
        )

      {:ok, %{"credentialRef" => ^reference, "status" => ^status}} = Wotex.JSON.decode(output)
      false = String.contains?(output, [pem, "PRIVATE KEY", directory])
      false = File.exists?("/tmp/forged-credentials")
    end

    "linux-pem-v1:" <> hex = reference
    path = "/var/lib/frameshift/credentials/" <> hex <> ".pem"
    ^pem = File.read!(path)
    0o400 = Bitwise.band(File.stat!(path).mode, 0o7777)

    {_, 69} =
      System.cmd(
        "runuser",
        ["-u", "frame-control", "--", "/usr/bin/frameshift-identity", "import"],
        stderr_to_stdout: true
      )

    File.rm!(input)
    reference
  end

  defp active_verification(backup, restored, uid) do
    port =
      Port.open({:spawn_executable, ~c"/usr/sbin/runuser"}, [
        :binary,
        :exit_status,
        args: ["-u", "frameshift", "--", "/usr/lib/frameshift/launch-service"]
      ])

    wait_ready(100)
    {"verify: ok\n", 0} = maintenance(["verify", backup])
    {_, 69} = maintenance(["restore", backup, restored <> "-live-refused"])
    false = File.exists?(restored <> "-live-refused")

    [pid] =
      File.ls!("/proc")
      |> Enum.filter(fn pid ->
        case File.read("/proc/" <> pid <> "/comm") do
          {:ok, "beam.smp\n"} -> File.stat!("/proc/" <> pid).uid == uid
          _ -> false
        end
      end)

    {_, 0} = System.cmd("kill", ["-TERM", pid])
    exit_status(port)
  end

  defp wait_ready(tries) do
    case System.cmd("runuser", ["-u", "frame-control", "--", "/usr/bin/frameshiftctl", "state"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        true = tries > 0
        Process.sleep(100)
        wait_ready(tries - 1)
    end
  end

  defp exit_status(port) do
    receive do
      {^port, {:data, _}} -> exit_status(port)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> raise "fixture process exited #{status}"
    after
      45_000 -> raise "fixture process did not exit"
    end
  end

  defp account(option) do
    {value, 0} = System.cmd("id", [option, "frameshift"])
    value |> String.trim() |> String.to_integer()
  end

  defp maintenance(args, env \\ []),
    do:
      System.cmd("runuser", ["-u", "frameshift", "--", "/usr/bin/frameshift-maintenance"] ++ args,
        stderr_to_stdout: true,
        env: env
      )

  defp files(path),
    do: [
      path
      | if(File.lstat!(path).type == :directory,
          do: Enum.flat_map(File.ls!(path), &files(Path.join(path, &1))),
          else: []
        )
    ]
end

FrameshiftUbuntuMaintenanceFixture.run()
