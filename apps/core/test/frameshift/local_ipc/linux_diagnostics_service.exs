Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

# This finite store double exercises the actual diagnostic dispatcher and its
# Library wrapper, without loading a host-native Exqlite NIF into Linux.
defmodule Frameshift.LinuxDiagnosticsFixtureStore do
  @moduledoc false

  use GenServer

  @impl true
  def init(_), do: {:ok, 0}

  @impl true
  def handle_call(:diagnostics_health, _, count) do
    {:reply, %{"fixture" => true, "queryCount" => count + 1}, count + 1}
  end
end

[path, control, wrong_owner, symlink_target] = System.argv()
gid = 50
alias Frameshift.LocalIPC.SocketDirectory

{:ok, store} = GenServer.start_link(Frameshift.LinuxDiagnosticsFixtureStore, nil)
{:ok, tasks} = Task.Supervisor.start_link(max_children: 17)

# Refused targets retain their prior permissions; no listener is opened.
{:error, :unsafe_socket_directory} = SocketDirectory.prepare_group(wrong_owner, gid)
{:ok, %File.Stat{mode: wrong_mode, uid: 0}} = File.lstat(Path.dirname(wrong_owner))
0o755 = Bitwise.band(wrong_mode, 0o7777)

linked_parent = Path.dirname(path) <> "-linked"
:ok = File.ln_s(symlink_target, linked_parent)

{:error, :unsafe_socket_directory} =
  SocketDirectory.prepare_group(Path.join(linked_parent, "d.sock"), gid)

{:ok, %File.Stat{mode: target_mode}} = File.lstat(symlink_target)
0o755 = Bitwise.band(target_mode, 0o7777)
File.rm!(linked_parent)

unassigned = Path.dirname(path) <> "-unassigned"
File.mkdir_p!(unassigned)
File.chmod!(unassigned, 0o700)

{:error, :eperm} =
  SocketDirectory.prepare_group(Path.join(unassigned, "d.sock"), 1)

{:ok, %File.Stat{gid: 65_534, mode: unassigned_mode}} = File.lstat(unassigned)
0o700 = Bitwise.band(unassigned_mode, 0o7777)
File.rm_rf!(unassigned)

parent = Path.dirname(path)
File.mkdir_p!(parent)
File.chmod!(parent, 0o700)
File.write!(path, "placeholder")
{:error, :unsafe_socket_path} = SocketDirectory.prepare_group(path, gid)
"placeholder" = File.read!(path)
{:ok, %File.Stat{mode: unchanged_mode}} = File.lstat(parent)
0o700 = Bitwise.band(unchanged_mode, 0o7777)
File.rm!(path)

# A final endpoint symlink also refuses without touching the linked file.
:ok = File.ln_s(Path.join(symlink_target, "target"), path)
{:error, :unsafe_socket_path} = SocketDirectory.prepare_group(path, gid)
"untouched" = File.read!(Path.join(symlink_target, "target"))
File.rm!(path)

{:ok, stale} = :socket.open(:local, :stream, :default)
:ok = :socket.bind(stale, %{family: :local, path: path})
:socket.close(stale)
{:ok, 65_534} = SocketDirectory.prepare_group(path, gid)
{:error, :enoent} = File.lstat(path)

{:ok, server} =
  Frameshift.LocalIPC.DiagnosticsServer.start_link(
    path: path,
    group_gid: gid,
    library: store,
    metrics: :absent_fixture_collector,
    task_supervisor: tasks,
    name: nil
  )

:ok = SocketDirectory.validate_group_socket(path, gid, 65_534)
{:error, :socket_already_active} = SocketDirectory.prepare_group(path, 1)
:ok = SocketDirectory.validate_group_socket(path, gid, 65_534)
{:ok, closed} = :socket.open(:local, :stream, :default)
:socket.close(closed)
{:error, _} = Frameshift.LocalIPC.PeerIdentity.credentials(closed)

File.write!(Path.join(control, "ready"), "ready")

# The service owner changes its own inode to exercise per-connection refusal.
# Root is only the fixture orchestrator; all listener operations run as nobody.
wait = fn wait, command, attempts ->
  cond do
    File.exists?(Path.join(control, command)) ->
      :ok

    attempts == 0 ->
      raise "fixture control timeout"

    true ->
      Process.sleep(10)
      wait.(wait, command, attempts - 1)
  end
end

wait.(wait, "loosen", 2_000)
File.chmod!(path, 0o666)
File.write!(Path.join(control, "loosened"), "done")
wait.(wait, "restore", 2_000)
File.chmod!(path, 0o660)
File.write!(Path.join(control, "restored"), "done")
wait.(wait, "stop", 2_000)
GenServer.stop(server)
{:error, :enoent} = File.lstat(path)
GenServer.stop(store)
Supervisor.stop(tasks)
File.rm_rf!(parent)
