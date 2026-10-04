Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

ExUnit.start()

defmodule Frameshift.Discovery.LinuxAvahiJoin do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Discovery.Avahi

  setup_all do
    File.mkdir_p!("/run/dbus")

    {_, 0} =
      System.cmd("dbus-daemon", ["--system", "--fork", "--nopidfile"], stderr_to_stdout: true)

    start_daemon()
    :ok
  end

  test "actual Avahi producer resolves through the clean Linux CLI and rejects private and duplicate device introductions" do
    publisher = publish("opaque-fixture", [])

    try do
      assert {:ok, snapshot} = Avahi.browse()
      assert snapshot["authority"] == "introduction"
      assert [%{"deviceId" => "paper-frame-00001", "origin" => origin}] = snapshot["frames"]
      {:ok, interfaces} = :inet.getifaddrs()

      addresses =
        Enum.find_value(interfaces, fn {name, values} ->
          if to_string(name) == "eth0", do: Keyword.get_values(values, :addr)
        end)

      {:ok, selected_address} = :inet.parse_address(String.to_charlist(URI.new!(origin).host))
      assert selected_address in addresses
      assert URI.new!(origin).port == 8_443
      assert snapshot["omittedCount"] == 0

      # A caller override must not replace the installed system bus.
      System.put_env("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=/tmp/untrusted-bus")

      code =
        "Code.prepend_paths(Path.wildcard(\"/src/_build/test/lib/*/ebin\")); Frameshift.CLI.main(System.argv())"

      assert {output, 0} =
               System.cmd(
                 "runuser",
                 ["-u", "nobody", "--", "elixir", "-e", code, "--", "discover"],
                 stderr_to_stdout: true
               )

      assert JSON.decode!(output) == snapshot
      System.delete_env("DBUS_SYSTEM_BUS_ADDRESS")
      refute output =~ "opaque-fixture"
      refute output =~ "eth0"
      assert Process.whereis(Frameshift.Library) == nil

      private = publish("private-fixture", ["owner=private room;artwork"])
      duplicate = publish("duplicate-fixture", ["id=another-frame-0001"])

      try do
        assert {:ok, %{"frames" => [_], "omittedCount" => 2}} = Avahi.browse()
      after
        stop_publisher(private)
        stop_publisher(duplicate)
      end

      conflicting = publish("conflicting-fixture", [])

      try do
        assert {:ok, %{"frames" => [], "omittedCount" => omitted}} = Avahi.browse()
        assert omitted >= 2
      after
        stop_publisher(conflicting)
      end
    after
      stop_publisher(publisher)
      System.delete_env("DBUS_SYSTEM_BUS_ADDRESS")
    end

    {_, 0} = System.cmd("avahi-daemon", ["--kill"], stderr_to_stdout: true)
    assert {69, "", "frameshiftctl: discovery unavailable\n"} = Frameshift.CLI.run(["discover"])
    start_daemon()
    publisher = publish("restarted-fixture", [])

    try do
      assert {:ok, %{"frames" => [%{"deviceId" => "paper-frame-00001"}]}} = Avahi.browse()
    after
      stop_publisher(publisher)
    end
  end

  defp start_daemon do
    File.write!(
      "/tmp/avahi.conf",
      "[server]\nhost-name=frameshift-fixture\ndomain-name=local\nuse-ipv4=yes\nuse-ipv6=no\nallow-interfaces=eth0\nenable-dbus=yes\n[publish]\npublish-workstation=no\n[reflector]\nenable-reflector=no\n"
    )

    {_, 0} =
      System.cmd(
        "avahi-daemon",
        ["--daemonize", "--no-drop-root", "--no-chroot", "--file=/tmp/avahi.conf"],
        stderr_to_stdout: true
      )
  end

  defp publish(name, extra) do
    port =
      Port.open({:spawn_executable, "/usr/bin/avahi-publish-service"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args:
          [
            name,
            "_frameshift._tcp",
            "8443",
            "v=0",
            "id=paper-frame-00001",
            "td=/.well-known/wot",
            "scheme=https",
            "pair=1"
          ] ++ extra
      ])

    await_publisher(port, "", System.monotonic_time(:millisecond) + 5_000)
    port
  end

  defp stop_publisher(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        {_, 0} =
          System.cmd("/bin/sh", ["-c", ~s(kill -TERM "$1"), "--", Integer.to_string(pid)],
            stderr_to_stdout: true
          )

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          1_000 -> flunk("publisher shutdown deadline")
        end

      nil ->
        :ok
    end
  end

  defp await_publisher(port, bytes, deadline) do
    receive do
      {^port, {:data, more}} ->
        bytes = bytes <> more

        if bytes =~ "Established under name",
          do: :ok,
          else: await_publisher(port, bytes, deadline)

      {^port, {:exit_status, code}} ->
        flunk("publisher exited: #{code}")
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> flunk("publisher deadline")
    end
  end
end
