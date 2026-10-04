defmodule Frameshift.LocalIPC.AdmissionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Diagnostics.Metrics
  alias Frameshift.Library
  alias Frameshift.LocalAPI
  alias Frameshift.LocalIPC.DiagnosticsServer
  alias Frameshift.LocalIPC.Server

  @token String.duplicate("a", 64)

  setup do
    root = "/tmp/fs-admit-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, tasks} = Task.Supervisor.start_link(max_children: 64)
    {:ok, diagnostic_tasks} = Task.Supervisor.start_link(max_children: 17)
    {:ok, library} = Library.start_link(data_dir: Path.join(root, "data"), name: nil)
    {:ok, metrics} = Metrics.start_link(library: library, name: nil)
    command_path = Path.join(root, "run/command.sock")
    diagnostic_path = Path.join(root, "run/diagnostic.sock")

    {:ok, command_server} =
      Server.start_link(
        path: command_path,
        token: @token,
        library: library,
        task_supervisor: tasks,
        name: nil
      )

    {:ok, diagnostic_server} =
      DiagnosticsServer.start_link(
        path: diagnostic_path,
        library: library,
        metrics: metrics,
        task_supervisor: diagnostic_tasks,
        name: nil
      )

    on_exit(fn ->
      for process <- [
            command_server,
            diagnostic_server,
            metrics,
            library,
            tasks,
            diagnostic_tasks
          ],
          do: stop_process(process)

      File.rm_rf!(root)
    end)

    %{
      tasks: tasks,
      diagnostic_tasks: diagnostic_tasks,
      library: library,
      command_path: command_path,
      diagnostic_path: diagnostic_path
    }
  end

  test "sixteen idle command workers refuse overflow without a claim and recover after disconnect",
       c do
    clients = Enum.map(1..16, fn _ -> connect(c.command_path) end)
    wait_count(c.tasks, 17)
    before = Library.audit_page(c.library)
    overflow = connect(c.command_path)
    send_request(overflow, command("overflow-command"))
    assert_closed(overflow)
    assert count(c.tasks) == 17
    assert Library.audit_page(c.library) == before
    assert LocalAPI.snapshot(c.library)["instruction"] == ""
    assert %{"ok" => true} = request(c.diagnostic_path, health())
    Enum.each(clients, &:gen_tcp.close/1)
    wait_count(c.tasks, 1)

    assert %{"ok" => true, "snapshot" => %{"instruction" => "Accepted"}} =
             request(c.command_path, command("overflow-command"))

    wait_count(c.tasks, 1)
  end

  test "the sixty-four task ceiling reserves independent diagnostic reads", c do
    blockers =
      for _ <- 1..63 do
        {:ok, worker} =
          Task.Supervisor.start_child(c.tasks, fn ->
            receive do
              :release -> :ok
            end
          end)

        worker
      end

    assert count(c.tasks) == 64
    assert {:error, :max_children} = Task.Supervisor.start_child(c.tasks, fn -> :ok end)
    before = Library.audit_page(c.library)
    assert %{"ok" => true} = request(c.diagnostic_path, health())
    overflow = connect(c.command_path)
    send_request(overflow, command("full-supervisor"))
    assert_closed(overflow)
    assert Library.audit_page(c.library) == before
    Enum.each(blockers, &send(&1, :release))
    wait_count(c.tasks, 1)
    assert %{"ok" => true} = request(c.command_path, command("full-supervisor"))
  end

  test "sixteen partial diagnostic workers also refuse overflow and restore capacity", c do
    clients =
      Enum.map(1..16, fn _ ->
        socket = connect(c.diagnostic_path, 0)
        # A raw length prefix arrives without its declared payload.
        :gen_tcp.send(socket, <<64::unsigned-big-32>>)
        socket
      end)

    wait_count(c.diagnostic_tasks, 17)
    overflow = connect(c.diagnostic_path)
    send_request(overflow, health())
    assert_closed(overflow)
    assert count(c.diagnostic_tasks) == 17
    assert %{"ok" => true} = request(c.command_path, command("diagnostic-pressure"))
    Enum.each(clients, &:gen_tcp.close/1)
    wait_count(c.diagnostic_tasks, 1)
    assert %{"ok" => true} = request(c.diagnostic_path, health())
  end

  test "stalled reads expire and release both listeners without domain mutation", c do
    command_socket = connect(c.command_path)
    diagnostic_socket = connect(c.diagnostic_path, 0)
    :ok = :gen_tcp.send(diagnostic_socket, <<64::unsigned-big-32>>)
    :ok = :inet.setopts(diagnostic_socket, packet: 4)
    wait_count(c.tasks, 2)
    wait_count(c.diagnostic_tasks, 2)
    before = Library.audit_page(c.library)
    {:ok, command_error} = :gen_tcp.recv(command_socket, 0, 6_000)
    assert Jason.decode!(command_error)["error"]["code"] == "request_timeout"
    {:ok, diagnostic_error} = :gen_tcp.recv(diagnostic_socket, 0, 1_000)
    assert Jason.decode!(diagnostic_error)["error"]["code"] == "invalid_request"
    :gen_tcp.close(command_socket)
    :gen_tcp.close(diagnostic_socket)
    wait_count(c.tasks, 1)
    wait_count(c.diagnostic_tasks, 1)
    assert Library.audit_page(c.library) == before
    assert %{"ok" => true} = request(c.command_path, command("after-read-deadline"))
    assert %{"ok" => true} = request(c.diagnostic_path, health())
  end

  defp command(id),
    do: %{
      "version" => 1,
      "requestId" => id,
      "auth" => @token,
      "operation" => "command",
      "command" => %{"id" => id, "kind" => "updateInstruction", "instruction" => "Accepted"}
    }

  defp health, do: %{"version" => 1, "requestId" => "health", "operation" => "health"}

  defp connect(path, packet \\ 4) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, packet: packet, active: false], 1_000)

    socket
  end

  defp send_request(socket, request) do
    assert :gen_tcp.send(socket, Jason.encode!(request)) in [
             :ok,
             {:error, :closed},
             {:error, :econnreset}
           ]
  end

  defp assert_closed(socket) do
    assert :gen_tcp.recv(socket, 0, 1_000) in [{:error, :closed}, {:error, :econnreset}]
    :gen_tcp.close(socket)
  end

  defp request(path, request) do
    socket = connect(path)
    send_request(socket, request)
    {:ok, payload} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)
    Jason.decode!(payload)
  end

  defp count(tasks), do: DynamicSupervisor.count_children(tasks).active

  defp stop_process(process) do
    if Process.alive?(process), do: GenServer.stop(process)
  catch
    :exit, _ -> :ok
  end

  defp wait_count(tasks, expected, attempts \\ 100)

  defp wait_count(tasks, expected, attempts) when attempts > 0 do
    if count(tasks) != expected do
      Process.sleep(10)
      wait_count(tasks, expected, attempts - 1)
    end
  end

  defp wait_count(tasks, expected, 0), do: assert(count(tasks) == expected)
end
