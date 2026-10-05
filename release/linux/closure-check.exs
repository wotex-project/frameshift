defmodule FrameshiftLinuxClosureFixture do
  @moduledoc false

  def run do
    true = length(:public_key.cacerts_get()) > 0
    0 = command("/usr/lib/frameshift/provision-runtime", [])
    before = File.stat!("/var/lib/frameshift/tmp")
    0 = command("/usr/lib/frameshift/provision-runtime", [])
    ^before = File.stat!("/var/lib/frameshift/tmp")
    uid = account("frameshift")
    control = account("frame-control")
    true = uid > 0 and control > 0 and uid != control

    69 =
      command("runuser", ["-u", "frame-control", "--", "/usr/lib/frameshift/provision-runtime"])

    unsafe_directories()

    {"frameshiftctl 0.1.0-dev\n", 0} = cli("frame-control", ["--version"])
    {_, 0} = cli("frame-observer", ["--help"])

    {"frameshift-identity 0.1.0-dev\n", 0} =
      System.cmd("runuser", [
        "-u",
        "frameshift",
        "--",
        "/usr/bin/frameshift-identity",
        "--version"
      ])

    69 =
      command("runuser", [
        "-u",
        "frame-control",
        "--",
        "/usr/bin/frameshift-identity",
        "--version"
      ])

    false = File.exists?("/var/lib/frameshift/metadata.sqlite")
    {_, 69} = cli("frame-control", ["state"])

    {"frameshiftctl 0.1.0-dev\n", 0} =
      cli("frame-control", ["--version"], [
        {"FRAMESHIFT_SERVICE_UID", "0"},
        {"ERL_FLAGS", "invalid"}
      ])

    run_service()
  end

  defp run_service do
    first = start()
    %{"ok" => true} = json_cli("frame-control", ["state"])
    %{"ok" => true} = json_cli("frame-observer", ["diagnostics", "health"])
    {_, 69} = cli("frame-observer", ["state"])
    {_, 69} = cli("frame-denied", ["diagnostics", "health"])
    {_, 69} = cli("frame-denied", ["state"])

    %{"ok" => true} =
      json_cli("frame-control", ["instruction", "Ubuntu original", "--id", "ubuntu-command"])

    caller = "/tmp/private-caller"
    File.mkdir!(caller)
    File.chown!(caller, account("frame-control"))
    File.chmod!(caller, 0o700)

    chunk = fn type, bytes ->
      <<byte_size(bytes)::32, type::binary, bytes::binary, :erlang.crc32(type <> bytes)::32>>
    end

    png =
      <<137, "PNG\r\n", 26, 10>> <>
        chunk.("IHDR", <<2::32, 1::32, 8, 6, 0, 0, 0>>) <>
        chunk.("IDAT", :zlib.compress(<<0, 255, 0, 0, 255, 0, 255, 0, 128>>)) <>
        chunk.("IEND", <<>>)

    for {name, bytes} <- [
          {"original.png", png},
          {"original.jpg", File.read!("/fixtures/canonical-jpeg.jpg")}
        ] do
      file = Path.join(caller, name)
      File.write!(file, bytes)
      File.chown!(file, account("frame-control"))
      File.chmod!(file, 0o600)
      {_, 1} = System.cmd("runuser", ["-u", "frameshift", "--", "test", "-r", file])

      %{"ok" => true, "import" => %{"status" => "succeeded", "importedItemID" => item}} =
        json_cli("frame-control", ["import", file, "--id", "ubuntu-" <> name])

      true = Frameshift.Digest.valid_sha256?(item)
      File.rm!(file)

      %{"ok" => true, "import" => %{"status" => "succeeded", "importedItemID" => ^item}} =
        json_cli("frame-control", ["import-status", "ubuntu-" <> name])
    end

    stop(first, "TERM")

    {output, 0} =
      clean("frameshift", "/fixtures/verify-store.exs", [
        Integer.to_string(account("frame-control"))
      ])

    true = String.contains?(output, "Exact SQLite/original/pixel/codec readback passed")
    second = start()

    for name <- ["original.png", "original.jpg"] do
      %{"ok" => true, "import" => %{"status" => "succeeded"}} =
        json_cli("frame-control", ["import-status", "ubuntu-" <> name])
    end

    stop(second, "KILL")
    true = File.dir?("/var/lib/frameshift/tmp/frameshift-import-custody")
    third = start()

    %{"ok" => true, "import" => %{"status" => "succeeded"}} =
      json_cli("frame-control", ["import-status", "ubuntu-original.jpg"])

    file = Path.join(caller, "after-crash.jpg")
    File.write!(file, File.read!("/fixtures/canonical-jpeg.jpg"))
    File.chown!(file, account("frame-control"))
    File.chmod!(file, 0o600)
    {output, 69} = cli("frame-control", ["import", file, "--id", "after-crash"])
    true = String.contains?(output, "import_unavailable")
    true = File.dir?("/var/lib/frameshift/tmp/frameshift-import-custody")
    stop(third, "TERM")

    IO.puts(
      "Ubuntu release closure passed: clean CLI, nonroot groups, PNG/JPEG, exact readback, VM restart and abandoned-custody refusal"
    )
  end

  defp unsafe_directories do
    path = "/var/lib/frameshift/tmp"
    File.chmod!(path, 0o755)
    69 = command("/usr/lib/frameshift/provision-runtime", [])
    0o755 = Bitwise.band(File.stat!(path).mode, 0o7777)
    File.chmod!(path, 0o700)
    File.rename!(path, path <> "-retained")
    File.mkdir!("/tmp/unrelated")
    File.chmod!("/tmp/unrelated", 0o755)
    File.write!("/tmp/unrelated/sentinel", "unchanged")
    File.ln_s!("/tmp/unrelated", path)
    before = File.stat!("/tmp/unrelated")
    69 = command("/usr/lib/frameshift/provision-runtime", [])
    ^before = File.stat!("/tmp/unrelated")
    "unchanged" = File.read!("/tmp/unrelated/sentinel")
    File.rm!(path)
    File.rename!(path <> "-retained", path)
    File.chown!(path, 0)
    69 = command("/usr/lib/frameshift/provision-runtime", [])
    0 = File.stat!(path).uid
    File.chown!(path, account("frameshift"))
    File.chgrp!(path, 0)
    69 = command("/usr/lib/frameshift/provision-runtime", [])
    0 = File.stat!(path).gid
    {gid, 0} = System.cmd("id", ["-g", "frameshift"])
    File.chgrp!(path, gid |> String.trim() |> String.to_integer())
    0 = command("/usr/lib/frameshift/provision-runtime", [])
  end

  defp start do
    port =
      Port.open({:spawn_executable, ~c"/usr/sbin/runuser"}, [
        :binary,
        :exit_status,
        args: ["-u", "frameshift", "--", "/usr/lib/frameshift/launch-service"]
      ])

    wait(
      fn ->
        File.exists?("/run/frameshift/control/c.sock") and
          match?({_, 0}, cli("frame-control", ["state"]))
      end,
      100
    )

    port
  end

  defp stop(port, signal) do
    pid =
      File.ls!("/proc")
      |> Enum.filter(&Regex.match?(~r/\A[0-9]+\z/, &1))
      |> Enum.find(fn pid ->
        case File.read("/proc/" <> pid <> "/comm") do
          {:ok, "beam.smp\n"} ->
            case File.stat("/proc/" <> pid) do
              {:ok, %{uid: uid}} -> uid == account("frameshift")
              _ -> false
            end

          _ ->
            false
        end
      end)

    true = is_binary(pid)
    0 = command("kill", ["-" <> signal, pid])
    await_exit(port)
  end

  defp await_exit(port) do
    receive do
      {^port, {:data, _}} -> await_exit(port)
      {^port, {:exit_status, _}} -> :ok
    after
      45_000 -> raise "host VM did not exit"
    end
  end

  defp wait(predicate, tries) do
    if predicate.(),
      do: :ok,
      else:
        (
          true = tries > 0
          Process.sleep(100)
          wait(predicate, tries - 1)
        )
  end

  defp account(name) do
    {uid, 0} = System.cmd("id", ["-u", name])
    uid |> String.trim() |> String.to_integer()
  end

  defp command(executable, args) do
    {_, status} = System.cmd(executable, args, stderr_to_stdout: true)
    status
  end

  defp cli(user, args, env \\ []),
    do:
      System.cmd("runuser", ["-u", user, "--", "/usr/bin/frameshiftctl"] ++ args,
        stderr_to_stdout: true,
        env: env
      )

  defp json_cli(user, args) do
    {output, 0} = cli(user, args)
    {:ok, json} = Wotex.JSON.decode(output)
    json
  end

  defp clean(user, script, args) do
    [_, version] =
      "/usr/lib/frameshift/core/releases/start_erl.data" |> File.read!() |> String.split()

    release = "/usr/lib/frameshift/core/releases/" <> version

    System.cmd(
      "runuser",
      [
        "-u",
        user,
        "--",
        release <> "/elixir",
        "--boot",
        release <> "/start_clean",
        "--boot-var",
        "RELEASE_LIB",
        "/usr/lib/frameshift/core/lib",
        script
      ] ++ args,
      env: [{"TMPDIR", "/var/lib/frameshift/tmp"}],
      stderr_to_stdout: true
    )
  end
end

FrameshiftLinuxClosureFixture.run()
