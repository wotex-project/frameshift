defmodule FrameshiftLinuxDEBFixture do
  @moduledoc false

  def run do
    # The joined release fixture qualifies actual installed bytes and leaves
    # deliberate crash custody for package lifecycle preservation below.
    Code.require_file("/fixtures/closure-check.exs")
    Code.require_file("/fixtures/maintenance-check.exs")
    credential = "/var/lib/frameshift/credentials/retained-fixture"
    File.write!(credential, "private credential custody sentinel")
    {service_uid, 0} = System.cmd("id", ["-u", "frameshift"])
    {service_gid, 0} = System.cmd("id", ["-g", "frameshift"])
    File.chown!(credential, service_uid |> String.trim() |> String.to_integer())
    File.chgrp!(credential, service_gid |> String.trim() |> String.to_integer())
    File.chmod!(credential, 0o600)
    before = snapshot()
    [initial] = Path.wildcard("/archives/*fixture1*.deb")
    [upgrade] = Path.wildcard("/archives/*fixture2*.deb")
    0 = command("dpkg", ["-i", upgrade])
    "0.1.0~dev+fixture2\n" = File.read!("/var/lib/frameshift/.installed-version")
    ^before = snapshot()
    {uid, 0} = System.cmd("id", ["-u", "frameshift"])
    manager_scripts(upgrade)
    ^before = snapshot()
    installed_cli()
    # Re-run the installed handler: dpkg --configure rejects an already-configured package.
    0 = configure()
    ^before = snapshot()
    stamp = "/var/lib/frameshift/.installed-version"
    File.write!(stamp, "0.1.0~dev+fixture3\n")
    true = configure() != 0
    "0.1.0~dev+fixture3\n" = File.read!(stamp)
    File.write!(stamp, "0.1.0~dev+fixture2\n")
    File.rename!(stamp, stamp <> "-retained")
    true = configure() != 0
    true = command("dpkg", ["-i", upgrade]) != 0
    false = File.exists?(stamp)
    File.rename!(stamp <> "-retained", stamp)
    true = command("dpkg", ["-i", initial]) != 0
    "0.1.0~dev+fixture2\n" = File.read!("/var/lib/frameshift/.installed-version")
    ^before = snapshot()

    File.chmod!(stamp, 0o644)
    true = command("dpkg", ["-i", upgrade]) != 0
    0o644 = Bitwise.band(File.stat!(stamp).mode, 0o7777)
    File.chmod!(stamp, 0o600)
    ^before = snapshot()

    # Directory redirection must refuse before dpkg touches its target.
    prefix = "/usr/lib/frameshift/bin"
    File.cp_r!(prefix, prefix <> "-retained")
    File.rm_rf!(prefix)
    File.mkdir!("/tmp/unrelated-package-target")
    File.write!("/tmp/unrelated-package-target/sentinel", "untouched")
    File.ln_s!("/tmp/unrelated-package-target", prefix)
    true = command("dpkg", ["-i", upgrade]) != 0
    ["sentinel"] = File.ls!("/tmp/unrelated-package-target")
    "untouched" = File.read!("/tmp/unrelated-package-target/sentinel")
    File.rm!(prefix)
    File.cp_r!(prefix <> "-retained", prefix)
    File.rm_rf!(prefix <> "-retained")
    ^before = snapshot()

    0 = command("dpkg", ["--remove", "frameshift"])
    false = File.exists?("/usr/bin/frameshiftctl")
    false = File.exists?("/usr/lib/systemd/system/frameshift.service")
    {^uid, 0} = System.cmd("id", ["-u", "frameshift"])
    ^before = snapshot()
    true = command("dpkg", ["-i", initial]) != 0
    ^before = snapshot()
    0 = command("dpkg", ["--purge", "frameshift"])
    {^uid, 0} = System.cmd("id", ["-u", "frameshift"])
    ^before = snapshot()
    true = command("dpkg", ["-i", initial]) != 0
    ^before = snapshot()
    0 = command("dpkg", ["-i", upgrade])
    ^before = snapshot()
    "0.1.0~dev+fixture2\n" = File.read!(stamp)
    installed_cli()

    IO.puts(
      "Ubuntu DEB lifecycle passed: install, exact runtime/import, upgrade/reconfigure, downgrade before unpack, unsafe prefix/stamp, remove/purge/reinstall and retained UID/data/custody"
    )
  end

  defp snapshot do
    root = "/var/lib/frameshift"

    (files(root) ++ files("/var/backups/frameshift"))
    |> Enum.reject(&(&1 == Path.join(root, ".installed-version")))
    |> Map.new(fn path ->
      stat = File.lstat!(path)

      value =
        {stat.type, stat.uid, stat.gid, Bitwise.band(stat.mode, 0o7777),
         if(stat.type == :regular, do: Frameshift.Digest.sha256(File.read!(path)), else: nil)}

      {path, value}
    end)
  end

  defp installed_cli do
    case System.get_env("ERL_FLAGS", "") do
      "" ->
        :ok

      "+JMsingle true" ->
        # dpkg restores native launchers. Alter only this disposable emulation
        # image after checking the actual archives, as in the initial fixture.
        0 =
          command("sed", [
            "-i",
            "s/ERL_FLAGS='+S/ERL_FLAGS='+JMsingle true +S/",
            "/usr/bin/frameshiftctl",
            "/usr/bin/frameshift-maintenance"
          ])
    end

    {"frameshiftctl 0.1.0-dev\n", 0} =
      System.cmd("runuser", ["-u", "frame-control", "--", "/usr/bin/frameshiftctl", "--version"])

    {_, 69} =
      System.cmd("runuser", ["-u", "frame-control", "--", "/usr/bin/frameshiftctl", "state"],
        stderr_to_stdout: true
      )
  end

  defp manager_scripts(upgrade) do
    # Exercise installed maintainer scripts and the actual Ubuntu helper against
    # a controlled systemctl boundary. This provides no booted-manager evidence.
    tool = "/usr/bin/systemctl"
    policy = "/usr/sbin/policy-rc.d"
    original_policy = File.read!(policy)
    File.rename!(tool, tool <> "-retained")
    File.cp!("/fixtures/fixture-systemctl", tool)
    File.chmod!(tool, 0o755)
    File.write!("/tmp/fixture-systemctl.log", "")
    {gid, 0} = System.cmd("id", ["-g", "frameshift"])
    File.chgrp!("/tmp/fixture-systemctl.log", gid |> String.trim() |> String.to_integer())
    File.chmod!("/tmp/fixture-systemctl.log", 0o660)
    File.mkdir_p!("/run/systemd/system")

    try do
      File.write!(policy, "#!/bin/sh\nexit 0\n")

      0 =
        command("deb-systemd-helper", ["disable", "frameshift.service"], [
          {"DPKG_MAINTSCRIPT_PACKAGE", "frameshift"}
        ])

      File.write!("/tmp/fixture-service-active", "")
      0 = command("dpkg", ["-i", upgrade])
      true = File.exists?("/tmp/fixture-service-active")
      false = File.exists?("/run/frameshift-package-active")
      false = File.exists?("/etc/systemd/system/multi-user.target.wants/frameshift.service")
      installed_cli()
      maintenance_manager_query()

      stamp = "/var/lib/frameshift/.installed-version"
      File.chmod!(stamp, 0o644)
      true = command("dpkg", ["-i", upgrade]) != 0
      true = File.exists?("/tmp/fixture-service-active")
      false = File.exists?("/run/frameshift-package-active")
      File.chmod!(stamp, 0o600)

      File.write!(policy, "#!/bin/sh\nexit 101\n")
      true = command("dpkg", ["-i", upgrade]) != 0
      true = File.exists?("/tmp/fixture-service-active")
      File.write!(policy, "#!/bin/sh\nexit 0\n")
      File.write!("/tmp/fixture-stop-fails", "")
      true = command("dpkg", ["-i", upgrade]) != 0
      true = File.exists?("/tmp/fixture-service-active")
      File.rm!("/tmp/fixture-stop-fails")

      File.write!("/tmp/fixture-start-fails", "")
      true = command("dpkg", ["-i", upgrade]) != 0
      false = File.exists?("/tmp/fixture-service-active")
      "0.1.0~dev+fixture2\n" = File.read!(stamp)
      File.rm!("/tmp/fixture-start-fails")
      0 = command("dpkg", ["--configure", "frameshift"])
      true = File.exists?("/tmp/fixture-service-active")
      File.rm!("/tmp/fixture-service-active")
      File.write!("/tmp/fixture-systemctl.log", "")
      0 = configure()
      false = File.exists?("/tmp/fixture-service-active")

      false =
        String.contains?(File.read!("/tmp/fixture-systemctl.log"), "start frameshift.service")
    after
      File.rm!(tool)
      File.rename!(tool <> "-retained", tool)
      File.write!(policy, original_policy)
      File.rmdir!("/run/systemd/system")
    end
  end

  defp files(path) do
    [
      path
      | if(File.lstat!(path).type == :directory,
          do: Enum.flat_map(File.ls!(path), &files(Path.join(path, &1))),
          else: []
        )
    ]
  end

  defp configure do
    {_, status} =
      System.cmd("/var/lib/dpkg/info/frameshift.postinst", ["configure", "0.1.0~dev+fixture2"],
        env: [{"DPKG_MAINTSCRIPT_PACKAGE", "frameshift"}],
        stderr_to_stdout: true
      )

    status
  end

  defp maintenance_manager_query do
    backup = "/var/backups/frameshift/exact backup $() `literal`"
    args = ["-u", "frameshift", "--", "/usr/bin/frameshift-maintenance", "backup", backup]
    # Active and unknown manager states refuse before the maintenance VM starts.
    for state <- ["active", "activating", "deactivating", "failed", "unknown"] do
      File.write!("/tmp/fixture-unit-state", state <> "\n")
      File.chmod!("/tmp/fixture-unit-state", 0o644)
      69 = command("runuser", args)
    end

    File.write!("/tmp/fixture-unit-state", "inactive\n")
    1 = command("runuser", args, [{"DBUS_SYSTEM_BUS_ADDRESS", "invalid"}])
    File.write!("/tmp/fixture-query-fails", "")
    69 = command("runuser", args)

    0 =
      command("runuser", [
        "-u",
        "frameshift",
        "--",
        "/usr/bin/frameshift-maintenance",
        "verify",
        backup
      ])

    File.rm!("/tmp/fixture-query-fails")
    File.write!("/tmp/fixture-query-sleeps", "")
    started = System.monotonic_time(:millisecond)
    69 = command("runuser", args)
    true = System.monotonic_time(:millisecond) - started < 6_000
    File.rm!("/tmp/fixture-query-sleeps")
    File.rm!("/tmp/fixture-unit-state")
  end

  defp command(executable, args, env \\ []) do
    {output, status} = System.cmd(executable, args, stderr_to_stdout: true, env: env)
    if status != 0, do: IO.puts("Expected refusal or fixture failure (#{executable}): " <> output)
    status
  end
end

FrameshiftLinuxDEBFixture.run()
