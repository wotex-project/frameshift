defmodule Frameshift.LocalIPC.LifecycleTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.LocalIPC.DiagnosticsServer
  alias Frameshift.LocalIPC.Server

  test "supervisor shutdown unlinks both listeners and mixed authority opens neither" do
    Process.flag(:trap_exit, true)
    root = "/tmp/fs-ipc-stop-#{System.unique_integer([:positive, :monotonic])}"
    command = Path.join(root, "c.sock")
    diagnostic = Path.join(root, "d.sock")
    token = String.duplicate("a", 64)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :ambiguous_ipc_authentication} =
             Server.start_link(path: command, token: token, group_gid: 50, name: nil)

    assert {:error, :enoent} = File.lstat(root)
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Server, path: command, token: token, task_supervisor: tasks, name: nil},
          {DiagnosticsServer, path: diagnostic, task_supervisor: tasks, name: nil}
        ],
        strategy: :one_for_one
      )

    assert {:ok, %File.Stat{type: :other}} = File.lstat(command)
    assert {:ok, %File.Stat{type: :other}} = File.lstat(diagnostic)
    assert :ok = Supervisor.stop(supervisor)
    assert {:error, :enoent} = File.lstat(command)
    assert {:error, :enoent} = File.lstat(diagnostic)
    Supervisor.stop(tasks)
  end
end
