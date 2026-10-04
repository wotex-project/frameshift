Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

# This records the actual dispatcher's actor/claim/completion calls and one
# finite setting effect. Receipt persistence/replay is tested against SQLite
# in CommandActorTest; this process is not a replacement receipt implementation.
defmodule Frameshift.LinuxCommandFixtureStore do
  @moduledoc false

  use GenServer

  @impl true
  def init(_), do: {:ok, %{calls: [], instruction: "", mutations: 0}}

  @impl true
  def handle_call({:claim_command, id, hash, uid}, _, state),
    do: {:reply, {:ok, :execute}, record(state, {:claim, id, hash, uid})}

  def handle_call({:complete_command, id, hash, uid, outcome}, _, state),
    do: {:reply, :ok, record(state, {:complete, id, hash, uid, outcome})}

  def handle_call({:put_setting, "generation.instruction", value}, _, state),
    do: {:reply, :ok, %{state | instruction: value, mutations: state.mutations + 1}}

  def handle_call({:get_setting, "generation.instruction"}, _, state),
    do: {:reply, {:ok, state.instruction}, state}

  def handle_call({:get_setting, "frame.selected"}, _, state), do: {:reply, :not_found, state}
  def handle_call(:list_paired_frames, _, state), do: {:reply, [], state}
  def handle_call({:list_pinned_masters, _}, _, state), do: {:reply, [], state}
  def handle_call({:search, _, _}, _, state), do: {:reply, [], state}

  def handle_call(:diagnostics_health, _, state),
    do: {:reply, %{"fixture" => true, "mutations" => state.mutations}, state}

  defp record(state, call), do: %{state | calls: [call | state.calls]}
end

[path, control] = System.argv()
System.put_env("FRAMESHIFT_CONTROL_GID", "50")
System.put_env("FRAMESHIFT_DIAGNOSTICS_GID", "65534")
System.put_env("FRAMESHIFT_SOCKET_PATH", path)

System.put_env(
  "FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH",
  Path.join(Path.dirname(path) <> "-observer", "d.sock")
)

System.put_env("FRAMESHIFT_DATA_DIR", Path.dirname(path) <> "-data")
System.delete_env("FRAMESHIFT_IPC_TOKEN_FILE")
System.delete_env("FRAMESHIFT_CREDENTIAL_SOCKET")
Application.put_env(:frameshift_core, :start_library, false)
Application.put_env(:frameshift_core, :start_renderer, false)
Application.put_env(:frameshift_core, :start_local_ipc, true)

{:ok, store} =
  GenServer.start_link(Frameshift.LinuxCommandFixtureStore, nil, name: Frameshift.Library)

{:ok, application} = Frameshift.Application.start(:normal, [])
:ok = Frameshift.LocalIPC.SocketDirectory.validate_group_socket(path, 50, 65_534)

{:error, :socket_already_active} = Frameshift.LocalIPC.SocketDirectory.prepare_group(path, 1)
:ok = Frameshift.LocalIPC.SocketDirectory.validate_group_socket(path, 50, 65_534)
File.write!(Path.join(control, "ready"), "ready")

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

wait.(wait, "loosen", 3_000)
File.chmod!(path, 0o666)
File.write!(Path.join(control, "loosened"), "done")
wait.(wait, "restore", 3_000)
File.chmod!(path, 0o660)
File.write!(Path.join(control, "restored"), "done")
wait.(wait, "stop", 3_000)

%{
  calls: [{:complete, "actor-command", hash, 1, :ok}, {:claim, "actor-command", hash, 1}],
  mutations: 1
} =
  :sys.get_state(store)

true = Frameshift.Digest.valid_sha256?(hash)
Supervisor.stop(application)
{:error, :enoent} = File.lstat(path)
GenServer.stop(store)
File.rm_rf!(Path.dirname(path))
File.rm_rf!(Path.dirname(path) <> "-observer")
File.rm_rf!(Path.dirname(path) <> "-data")
