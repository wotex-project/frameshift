Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

ExUnit.start()
Code.require_file(Path.join(__DIR__, "group_configuration_test.exs"))

defmodule Frameshift.LocalIPC.LinuxPeerIdentityContract do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.LocalIPC.PeerIdentity

  test "reads the Linux kernel UID of the connected owner and another local user" do
    assert :os.type() == {:unix, :linux}
    path = "/tmp/frameshift-peer-#{System.unique_integer([:positive])}.sock"
    {:ok, listener} = :socket.open(:local, :stream, :default)

    on_exit(fn ->
      :socket.close(listener)
      File.rm(path)
    end)

    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    :ok = File.chmod(path, 0o777)

    {:ok, local} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(local, %{family: :local, path: path})
    {:ok, accepted_local} = :socket.accept(listener, 10_000)
    assert {:ok, 0} = PeerIdentity.uid(accepted_local)

    assert {:ok, %{pid: local_pid, uid: 0, gid: 0}} =
             PeerIdentity.credentials(accepted_local)

    assert local_pid > 0
    :socket.close(accepted_local)
    :socket.close(local)

    client =
      Task.async(fn ->
        System.cmd("runuser", ["-u", "nobody", "--", "elixir", "-e", client_code(path)],
          stderr_to_stdout: true
        )
      end)

    {:ok, accepted_other} = :socket.accept(listener, 10_000)
    assert {:ok, 65_534} = PeerIdentity.uid(accepted_other)

    assert {:ok, %{pid: other_pid, uid: 65_534, gid: 65_534}} =
             PeerIdentity.credentials(accepted_other)

    assert other_pid != local_pid
    :socket.close(accepted_other)
    assert {_, 0} = Task.await(client, 10_000)
  end

  defp client_code(path) do
    "{:ok, socket} = :socket.open(:local, :stream, :default); " <>
      ":ok = :socket.connect(socket, %{family: :local, path: #{inspect(path)}}); " <>
      ":socket.close(socket)"
  end
end

defmodule Frameshift.LocalIPC.LinuxDiagnosticsContract do
  @moduledoc false

  use ExUnit.Case, async: false

  setup_all do
    Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))
    assert Code.ensure_loaded?(Frameshift.LocalIPC.DiagnosticsServer)
    :ok
  end

  test "supplementary observers read the real dispatcher while denied users and changed custody refuse" do
    root = "/tmp/fg-control-#{System.unique_integer([:positive])}"
    service_root = root <> "-service"
    path = Path.join(service_root, "d.sock")
    File.mkdir_p!(root)
    File.chmod!(root, 0o777)
    wrong = Path.join(root, "wrong")
    target = Path.join(root, "target")
    File.mkdir_p!(wrong)
    File.mkdir_p!(target)
    File.chmod!(wrong, 0o755)
    File.chmod!(target, 0o755)
    File.write!(Path.join(target, "target"), "untouched")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(service_root)
    end)

    assert {:error, :unprivileged_service_required} =
             Frameshift.LocalIPC.SocketDirectory.prepare_group(path, 50)

    assert {:error, :enoent} = File.lstat(service_root)

    service =
      Task.async(fn ->
        System.cmd(
          "runuser",
          [
            "-u",
            "nobody",
            "-g",
            "nogroup",
            "-G",
            "staff",
            "--",
            "elixir",
            "/src/test/frameshift/local_ipc/linux_diagnostics_service.exs",
            path,
            root,
            Path.join(wrong, "d.sock"),
            target
          ],
          stderr_to_stdout: true
        )
      end)

    await_file(root, "ready", service)

    assert {:ok, %File.Stat{uid: 65_534, gid: 50, mode: directory_mode}} =
             File.lstat(service_root)

    assert Bitwise.band(directory_mode, 0o7777) == 0o710
    assert {:ok, %File.Stat{uid: 65_534, gid: 50, mode: socket_mode}} = File.lstat(path)
    assert Bitwise.band(socket_mode, 0o7777) == 0o660

    # daemon's primary group is 1, but supplementary staff (50) grants connect.
    assert {output, 0} = client(path, true, "health")
    assert output =~ "observer-primary-gid=1"
    assert output =~ ~s("fixture":true)
    assert output =~ ~s("ok":true)
    assert {denied, 0} = client(path, false, "health")
    assert denied =~ "eacces"
    refute denied =~ ~s("fixture":true)
    assert {mutation, 0} = client(path, true, "command")
    assert mutation =~ ~s("code":"invalid_request")
    assert {forged, 0} = client(path, true, "health", %{"uid" => 0, "gid" => 50})
    assert forged =~ ~s("code":"invalid_request")

    File.write!(Path.join(root, "loosen"), "go")
    await_file(root, "loosened", service)
    assert {changed, 0} = client(path, true, "health")
    assert changed =~ ~s("code":"authentication_required")
    refute changed =~ ~s("fixture":true)
    File.write!(Path.join(root, "restore"), "go")
    await_file(root, "restored", service)
    assert {restored, 0} = client(path, true, "health")
    assert restored =~ ~s("queryCount":2)
    File.write!(Path.join(root, "stop"), "go")
    assert {_, 0} = Task.await(service, 10_000)
    assert {:error, :enoent} = File.lstat(path)
  end

  defp client(path, observer, operation, extra \\ %{}) do
    request =
      Map.merge(%{"version" => 1, "requestId" => "observer", "operation" => operation}, extra)

    payload = RFC8785.encode!(request)

    code = """
    status = File.read!("/proc/self/status")
    row = status |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Gid:"))
    ["Gid:", primary_gid, _, _, _] = String.split(row)
    IO.puts("observer-primary-gid=" <> primary_gid)
    {:ok, socket} = :socket.open(:local, :stream, :default)
    case :socket.connect(socket, %{family: :local, path: #{inspect(path)}}, 2_000) do
      :ok ->
        bytes = #{inspect(payload)}
        :ok = :socket.send(socket, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>)
        {:ok, <<size::unsigned-big-32>>} = :socket.recv(socket, 4, 5_000)
        {:ok, response} = :socket.recv(socket, size, 5_000)
        IO.puts(response)
      {:error, reason} -> IO.puts(Atom.to_string(reason))
    end
    :socket.close(socket)
    """

    groups = if observer, do: ["-G", "staff"], else: []

    System.cmd(
      "runuser",
      ["-u", "daemon", "-g", "daemon"] ++ groups ++ ["--", "elixir", "-e", code],
      stderr_to_stdout: true
    )
  end

  defp await_file(root, name, service, attempts \\ 1_000)
  defp await_file(_, _, service, 0), do: flunk("service timeout: #{inspect(Task.yield(service))}")

  defp await_file(root, name, service, attempts) do
    cond do
      File.exists?(Path.join(root, name)) ->
        :ok

      result = Task.yield(service) ->
        flunk("service stopped: #{inspect(result)}")

      true ->
        Process.sleep(10)
        await_file(root, name, service, attempts - 1)
    end
  end
end
