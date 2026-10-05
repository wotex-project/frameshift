defmodule FrameshiftBootedPackageFixture do
  @moduledoc false

  def run do
    [lower, upper, lower_sha, upper_sha] = System.argv()

    for {path, digest} <- [{lower, lower_sha}, {upper, upper_sha}] do
      stat = File.lstat!(path)
      true = stat.type == :regular and stat.uid == 0 and stat.gid == 0 and stat.links == 1
      true = Bitwise.band(stat.mode, 0o7777) == 0o600 and stat.size in 1..(64 * 1024 * 1024)
      ^digest = Frameshift.Digest.hex!(Frameshift.Digest.sha256(File.read!(path)))
    end

    {"0\n", 0} = System.cmd("id", ["-u"])
    {"systemd\n", 0} = System.cmd("cat", ["/proc/1/comm"])
    {"arm64\n", 0} = System.cmd("dpkg", ["--print-architecture"])

    {"ubuntu:24.04", 0} =
      System.cmd("sh", ["-eu", "-c", ". /etc/os-release; printf '%s:%s' \"$ID\" \"$VERSION_ID\""])

    "mixed\n" = property("KillMode")
    "stop\n" = property("OOMPolicy")
    main = property("MainPID") |> String.trim()
    true = Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, main)
    "beam.smp\n" = File.read!("/proc/" <> main <> "/comm")

    69 =
      command("flock", [
        "--nonblock",
        "--conflict-exit-code",
        "69",
        "/var/lib/frameshift",
        "/bin/true"
      ])

    "0.1.0\n" = File.read!("/var/lib/frameshift/.installed-version")
    {uid, 0} = System.cmd("id", ["-u", "frameshift"])
    {gid, 0} = System.cmd("id", ["-g", "frameshift"])
    {actor, 0} = System.cmd("id", ["-u", "frame-control"])
    uid_int = String.to_integer(String.trim(uid))
    gid_int = String.to_integer(String.trim(gid))
    true = uid_int > 0
    active()
    imports(String.to_integer(String.trim(actor)))

    %{"ok" => true, "import" => %{"status" => "succeeded"}} =
      json_cli("frame-control", [
        "import",
        "/run/frameshift-qualification-fixtures/original.jpg",
        "--id",
        "systemd-fresh-jpeg"
      ])

    for role <- ["frame-observer", "frame-denied"], do: {_, 69} = cli(role, ["state"])
    reference = identity()
    unknown = "/var/lib/frameshift/tmp/package-qualification-unknown"
    false = File.exists?(unknown)
    File.mkdir!(unknown)
    File.chown!(unknown, uid_int)
    File.chgrp!(unknown, gid_int)
    File.chmod!(unknown, 0o700)
    File.write!(unknown <> "/fence", "unknown custody retained")
    File.chown!(unknown <> "/fence", uid_int)
    File.chgrp!(unknown <> "/fence", gid_int)
    File.chmod!(unknown <> "/fence", 0o600)
    backup = "/var/backups/frameshift/booted backup $() `literal`"
    restored = "/var/backups/frameshift/booted restored"
    {_, 69} = maintenance(["backup", backup])
    false = File.exists?(backup)
    0 = command("systemctl", ["stop", "frameshift.service"])
    "inactive\n" = property("ActiveState")
    {"backup: ok\n", 0} = maintenance(["backup", backup])
    {"verify: ok\n", 0} = maintenance(["verify", backup])
    {"restore: ok\n", 0} = maintenance(["restore", backup, restored])

    for path <- [backup, restored],
        name <- ["credentials", "tmp", ".installed-version"],
        do: false = File.exists?(Path.join(path, name))

    {output, 0} =
      clean_service("/run/frameshift-qualification-fixtures/verify-booted-store.exs", [
        restored,
        String.trim(actor),
        reference,
        "/run/frameshift-qualification-fixtures/original.jpg"
      ])

    true =
      String.contains?(
        output,
        "restored exact PNG/JPEG/receipt and separately retained identity passed"
      )

    baseline = snapshot()
    IO.puts("phase: backup/restore readback passed")
    start_service()
    {"verify: ok\n", 0} = maintenance(["verify", backup])
    0 = command("systemctl", ["disable", "frameshift.service"])
    "disabled\n" = property("UnitFileState")
    active()
    0 = command("dpkg", ["-i", upper])
    active()
    "disabled\n" = property("UnitFileState")
    {"frameshiftctl 0.1.1\n", 0} = cli("frame-control", ["--version"])
    "0.1.1\n" = File.read!("/var/lib/frameshift/.installed-version")
    {^uid, 0} = System.cmd("id", ["-u", "frameshift"])
    retained_imports()
    IO.puts("phase: active-but-disabled numeric upgrade passed")
    {_, 69} = maintenance(["restore", backup, restored <> "-live-refused"])
    false = File.exists?(restored <> "-live-refused")
    packaged = Frameshift.Digest.sha256(File.read!("/usr/bin/frameshiftctl"))
    true = command("dpkg", ["-i", lower]) != 0
    ^packaged = Frameshift.Digest.sha256(File.read!("/usr/bin/frameshiftctl"))
    "0.1.1\n" = File.read!("/var/lib/frameshift/.installed-version")
    active()
    0 = command("systemctl", ["stop", "frameshift.service"])
    retained!(baseline)
    start_service()
    IO.puts("phase: downgrade refusal/error-unwind passed")
    0 = command("dpkg", ["--remove", "frameshift"])
    false = File.exists?("/usr/bin/frameshiftctl")
    false = File.exists?("/usr/lib/systemd/system/frameshift.service")
    {^uid, 0} = System.cmd("id", ["-u", "frameshift"])
    retained!(baseline)
    true = command("dpkg", ["-i", lower]) != 0
    retained!(baseline)
    IO.puts("phase: remove/retained bytes passed")
    0 = command("dpkg", ["--purge", "frameshift"])
    retained!(baseline)
    true = command("dpkg", ["-i", lower]) != 0
    retained!(baseline)
    0 = command("dpkg", ["-i", upper])
    active()
    {"frameshiftctl 0.1.1\n", 0} = cli("frame-control", ["--version"])
    retained_imports()
    0 = command("systemctl", ["stop", "frameshift.service"])
    retained!(baseline)
    {^uid, 0} = System.cmd("id", ["-u", "frameshift"])
    start_service()

    %{"ok" => true, "import" => %{"status" => "succeeded"}} =
      json_cli("frame-control", [
        "import",
        "/tmp/frameshift-booted-caller/absolute.png",
        "--id",
        "booted-reinstalled-png"
      ])

    IO.puts(
      "Booted package lifecycle passed: actual 0.1.0 to 0.1.1 update, active-but-disabled restart, downgrade refusal/error-unwind, remove/purge/reinstall, exact retained data/identity/unknown custody, offline backup/restore and receipt readback"
    )

    native_stop(String.to_integer(String.trim(actor)))
  end

  defp native_stop(actor) do
    0 = command("systemctl", ["stop", "frameshift.service"])
    before = snapshot().tables
    {gid, 0} = System.cmd("id", ["-g", "frame-control"])
    path = "/tmp/frameshift-booted-caller/codec-stop.png"
    row = <<0>> <> :binary.copy(<<255>>, 4000 * 4)

    png =
      <<137, 80, 78, 71, 13, 10, 26, 10>> <>
        png_chunk("IHDR", <<4000::32, 2000::32, 8, 6, 0, 0, 0>>) <>
        png_chunk("IDAT", :zlib.compress(:binary.copy(row, 2000))) <> png_chunk("IEND", <<>>)

    File.write!(path, png)
    File.chown!(path, actor)
    File.chgrp!(path, String.to_integer(String.trim(gid)))
    File.chmod!(path, 0o600)
    start_service()

    {output, 0} =
      System.cmd(
        "timeout",
        [
          "--signal=TERM",
          "--kill-after=50",
          "100",
          "/run/frameshift-qualification-fixtures/codec-stop-check"
        ],
        stderr_to_stdout: true
      )

    true = String.contains?(output, "native-codec stop passed")
    true = snapshot().tables == before
    true = File.dir?("/var/lib/frameshift/tmp/frameshift-import-custody")
    start_service()
    retained_imports()
    {status, 69} = cli("frame-control", ["import-status", "booted-codec-stop"])
    true = String.contains?(status, "import_unavailable")

    {refusal, 69} =
      cli("frame-control", [
        "import",
        "/tmp/frameshift-booted-caller/absolute.png",
        "--id",
        "booted-after-uncertain-stop"
      ])

    true = String.contains?(refusal, "import_unavailable")
    true = File.read!(path) == png

    IO.puts(
      "Booted codec stop passed: actual stopped worker exits before inactive, authoritative tables unchanged, no pre-decode receipt fabricated, prior receipts readable, uncertain intake retained and new work refused"
    )
  end

  defp imports(actor) do
    {gid, 0} = System.cmd("id", ["-g", "frame-control"])
    caller = "/tmp/frameshift-booted-caller"
    false = File.exists?(caller)
    File.mkdir!(caller)
    File.chown!(caller, actor)
    File.chgrp!(caller, String.to_integer(String.trim(gid)))
    File.chmod!(caller, 0o700)
    header = <<2::32, 1::32, 8, 6, 0, 0, 0>>
    pixels = <<0, 255, 0, 0, 255, 0, 255, 0, 128>>

    png =
      <<137, 80, 78, 71, 13, 10, 26, 10>> <>
        png_chunk("IHDR", header) <>
        png_chunk("IDAT", :zlib.compress(pixels)) <> png_chunk("IEND", <<>>)

    golden = "/run/frameshift-qualification-fixtures/original.png"
    false = File.exists?(golden)
    File.write!(golden, png)
    File.chmod!(golden, 0o644)
    literal = "input $() `literal`.png"

    for name <- ["absolute.png", literal] do
      path = Path.join(caller, name)
      File.write!(path, png)
      File.chown!(path, actor)
      File.chgrp!(path, String.to_integer(String.trim(gid)))
      File.chmod!(path, 0o600)
    end

    %{"ok" => true, "import" => %{"status" => "succeeded", "importedItemID" => id}} =
      json_cli("frame-control", [
        "import",
        caller <> "/absolute.png",
        "--id",
        "systemd-fresh-absolute"
      ])

    {output, 0} =
      System.cmd(
        "runuser",
        [
          "-u",
          "frame-control",
          "--",
          "sh",
          "-eu",
          "-c",
          "cd \"$1\"; exec /usr/bin/frameshiftctl import \"$2\" --id systemd-fresh-literal",
          "fixture",
          caller,
          literal
        ],
        stderr_to_stdout: true,
        cd: "/root"
      )

    {:ok, %{"ok" => true, "import" => %{"status" => "succeeded", "importedItemID" => ^id}}} =
      Wotex.JSON.decode(output)
  end

  defp png_chunk(type, bytes) do
    <<byte_size(bytes)::32, type::binary-size(4), bytes::binary,
      :erlang.crc32(type <> bytes)::32>>
  end

  defp identity do
    uncertain_input = "/root/frameshift-qualification-key.pem"

    if File.exists?(uncertain_input) do
      old_pem = File.read!(uncertain_input)

      {:ok, "linux-pem-v1:" <> hex = old_reference} =
        Frameshift.Transport.ProtectedFile.identify(old_pem)

      target = "/var/lib/frameshift/credentials/" <> hex <> ".pem"
      before = File.lstat!(target)

      {output, 0} =
        System.cmd(
          "sh",
          [
            "-eu",
            "-c",
            "exec runuser -u frameshift -- /usr/bin/frameshift-identity import < \"$1\"",
            "fixture",
            uncertain_input
          ],
          stderr_to_stdout: true
        )

      {:ok, %{"credentialRef" => ^old_reference, "status" => "existing"}} =
        Wotex.JSON.decode(output)

      true = Map.delete(before, :atime) == Map.delete(File.lstat!(target), :atime)
      true = File.read!(target) == old_pem
      File.rm!(uncertain_input)
      IO.puts("previous uncertain identity: exact read-only replay passed")
    end

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

    input = "/root/frameshift-qualification-key.pem"
    false = File.exists?(input)
    File.write!(input, pem)
    File.chmod!(input, 0o600)

    {output, 0} =
      System.cmd(
        "sh",
        [
          "-eu",
          "-c",
          "exec runuser -u frameshift -- /usr/bin/frameshift-identity import < \"$1\"",
          "fixture",
          input
        ],
        stderr_to_stdout: true
      )

    reference = "linux-pem-v1:" <> Frameshift.Digest.hex!(Frameshift.Digest.sha256(certificate))
    {:ok, %{"credentialRef" => ^reference, "status" => "created"}} = Wotex.JSON.decode(output)
    false = String.contains?(output, [pem, "PRIVATE KEY"])
    File.rm!(input)
    reference
  end

  defp clean_service(script, args) do
    [_, version] =
      File.read!("/usr/lib/frameshift/core/releases/start_erl.data") |> String.split()

    release = "/usr/lib/frameshift/core/releases/" <> version

    System.cmd(
      "runuser",
      [
        "-u",
        "frameshift",
        "--",
        "env",
        "-i",
        "PATH=/usr/bin:/bin",
        "LANG=C.UTF-8",
        "ERL_FLAGS=+S 2:2 +SDcpu 2 +SDio 2",
        "ERL_CRASH_DUMP=/dev/null",
        release <> "/elixir",
        "--boot",
        release <> "/start_clean",
        "--boot-var",
        "RELEASE_LIB",
        "/usr/lib/frameshift/core/lib",
        script | args
      ],
      stderr_to_stdout: true,
      cd: "/"
    )
  end

  defp maintenance(args),
    do:
      System.cmd("runuser", ["-u", "frameshift", "--", "/usr/bin/frameshift-maintenance" | args],
        stderr_to_stdout: true
      )

  defp cli(user, args),
    do:
      System.cmd("runuser", ["-u", user, "--", "/usr/bin/frameshiftctl" | args],
        stderr_to_stdout: true
      )

  defp json_cli(user, args) do
    {output, 0} = cli(user, args)
    {:ok, value} = Wotex.JSON.decode(output)
    value
  end

  defp command(executable, args) do
    {_output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    status
  end

  defp property(key) do
    {value, 0} =
      System.cmd("systemctl", ["show", "frameshift.service", "--property=" <> key, "--value"])

    value
  end

  defp start_service do
    # Each planned stop/start begins an independent acceptance phase. Do not
    # relax the real unit's finite rapid-start budget or clear filesystem fences.
    case System.cmd("systemctl", ["reset-failed", "frameshift.service"],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {_, 0} ->
        :ok

      {"Failed to reset failed state of unit frameshift.service: Unit frameshift.service not loaded.\n",
       1} ->
        # The manager has no loaded failure/start-rate state to reset. Starting
        # below loads the still-installed unit; every other reset error refuses.
        :ok

      _ ->
        raise "booted unit failure-state reset unavailable"
    end

    0 = command("systemctl", ["start", "frameshift.service"])
    active()
  end

  defp active do
    "active\n" = property("ActiveState")
    wait_ready(40)
    %{"ok" => true} = json_cli("frame-observer", ["diagnostics", "health"])
  end

  defp wait_ready(0), do: raise("booted host readiness unavailable")

  defp wait_ready(left) do
    case cli("frame-control", ["state"]) do
      {output, 0} ->
        {:ok, %{"ok" => true}} = Wotex.JSON.decode(output)

      _ ->
        Process.sleep(250)
        wait_ready(left - 1)
    end
  end

  defp retained_imports do
    for name <- ["systemd-fresh-absolute", "systemd-fresh-literal", "systemd-fresh-jpeg"],
        do:
          %{"ok" => true, "import" => %{"status" => "succeeded"}} =
            json_cli("frame-control", ["import-status", name])
  end

  defp retained!(baseline) do
    current = snapshot()
    true = current.files == baseline.files
    true = current.tables == baseline.tables
    true = Enum.all?(baseline.audit, &(&1 in current.audit))
  end

  defp snapshot do
    "inactive\n" = property("ActiveState")

    files =
      ["/var/lib/frameshift", "/var/backups/frameshift"]
      |> Enum.flat_map(&paths/1)
      |> Enum.reject(fn path ->
        path in [
          "/var/lib/frameshift/.installed-version",
          "/var/lib/frameshift/metadata.sqlite-wal",
          "/var/lib/frameshift/metadata.sqlite-shm"
        ] or
          String.starts_with?(path, "/var/lib/frameshift/diagnostics/")
      end)
      |> Map.new(fn path ->
        stat = File.lstat!(path)
        true = stat.type in [:regular, :directory]

        digest =
          if stat.type == :regular and path != "/var/lib/frameshift/metadata.sqlite",
            do: Frameshift.Digest.sha256(File.read!(path)),
            else: nil

        {path, {stat.type, stat.uid, stat.gid, Bitwise.band(stat.mode, 0o7777), digest}}
      end)

    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, db} = Exqlite.Sqlite3.open("/var/lib/frameshift/metadata.sqlite", mode: :readonly)

    try do
      [["ok"]] = rows(db, "PRAGMA integrity_check")
      [] = rows(db, "PRAGMA foreign_key_check")

      tables =
        rows(db, "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name")
        |> Enum.map(fn [name] -> name end)
        |> Enum.reject(
          &(String.starts_with?(&1, "master_search") or
              &1 in ["sqlite_sequence", "audit_entries", "metric_rollups"])
        )
        |> Map.new(fn name ->
          true = Regex.match?(~r/\A[a-z_]+\z/, name)
          {name, rows(db, "SELECT * FROM " <> name) |> Enum.sort()}
        end)

      %{files: files, tables: tables, audit: rows(db, "SELECT * FROM audit_entries ORDER BY id")}
    after
      :ok = Exqlite.Sqlite3.close(db)
    end
  end

  defp rows(db, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      {:ok, values} = Exqlite.Sqlite3.fetch_all(db, statement)
      values
    after
      :ok = Exqlite.Sqlite3.release(db, statement)
    end
  end

  defp paths(path) do
    if File.lstat!(path).type == :directory,
      do: [path | Enum.flat_map(File.ls!(path) |> Enum.sort(), &paths(Path.join(path, &1)))],
      else: [path]
  end
end

FrameshiftBootedPackageFixture.run()
