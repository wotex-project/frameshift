defmodule Frameshift.LocalIPC.DiagnosticsServerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Diagnostics.Metrics
  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalIPC.DiagnosticsServer

  setup do
    root = "/tmp/fs-diag-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, library} = Library.start_link(data_dir: Path.join(root, "data"), name: nil)
    {:ok, metrics} = Metrics.start_link(library: library, name: nil)
    path = Path.join(root, "run/diagnostics.sock")

    {:ok, server} =
      DiagnosticsServer.start_link(
        path: path,
        library: library,
        metrics: metrics,
        task_supervisor: tasks,
        name: nil
      )

    on_exit(fn ->
      for process <- [server, metrics, library, tasks], Process.alive?(process) do
        try do
          GenServer.stop(process)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(root)
    end)

    %{library: library, metrics: metrics, path: path}
  end

  test "reads authoritative health and bounded persistent metric rollups", context do
    assert %{"ok" => true, "diagnostics" => health} = request(context.path, "health")
    assert health["store"]["pendingPush"] == 0
    assert health["store"]["metricPageBudgetBytes"] == 32 * 1024 * 1024
    assert health["store"]["metricPageMeasurementAvailable"]
    assert health["store"]["metricAllocatedBytes"] <= health["store"]["metricPageBudgetBytes"]
    assert health["collector"]["available"]
    assert health["fallbackLog"]["scope"] == "handler_configuration"
    assert health["fallbackLog"]["lossFreeSinceMs"] == nil
    refute Map.has_key?(health["fallbackLog"], "path")

    :telemetry.execute(
      [:frameshift, :command, :completed],
      %{count: 1, duration_ms: 37},
      %{outcome: :succeeded, frame_id: "forbidden-cardinality"}
    )

    assert :ok = Metrics.flush(context.metrics)

    assert %{"ok" => true, "diagnostics" => %{"store" => metric_store}} =
             request(context.path, "health")

    assert metric_store["metricAllocatedBytes"] > 0
    assert metric_store["metricAllocatedBytes"] <= metric_store["metricPageBudgetBytes"]

    :telemetry.execute(
      [:frameshift, :command, :completed],
      %{count: 1, duration_ms: 63},
      %{outcome: :succeeded}
    )

    assert :ok = Metrics.flush(context.metrics)

    assert %{
             "ok" => true,
             "diagnostics" => %{
               "entries" => entries,
               "catalog" => %{"version" => 2, "metrics" => catalog},
               "coverage" => coverage
             }
           } =
             request(context.path, "metrics")

    assert coverage["available"]
    assert coverage["resetAtMs"] == coverage["lossFreeSinceMs"]
    assert coverage["observedAtMs"] >= coverage["resetAtMs"]

    assert Enum.any?(catalog, fn definition ->
             definition["name"] == "frameshift.command.duration.ms" and
               definition["unit"] == "millisecond" and
               definition["aggregation"] == "distribution" and
               definition["upperBounds"] == [
                 5,
                 10,
                 25,
                 50,
                 100,
                 250,
                 500,
                 1_000,
                 2_500,
                 5_000,
                 10_000,
                 30_000
               ]
           end)

    assert Enum.any?(entries, &(&1["metric"] == "frameshift.command.duration.ms"))

    assert Enum.any?(entries, fn entry ->
             entry["metric"] == "frameshift.command.duration.ms" and
               entry["granularity"] == "minute" and entry["count"] == 2 and
               entry["sum"] == 100.0
           end)

    assert Enum.all?(entries, fn entry ->
             not Map.has_key?(entry["dimensions"], "frame_id") and
               not Map.has_key?(entry["dimensions"], "command_id")
           end)

    GenServer.stop(context.metrics)
    GenServer.stop(context.library)

    {:ok, restarted} =
      Library.start_link(data_dir: Path.join(Path.dirname(context.path), "../data"), name: nil)

    on_exit(fn -> Frameshift.TestSupport.stop_if_running(restarted) end)

    assert %{"entries" => persisted} = Library.metric_page(restarted)
    assert Enum.any?(persisted, &(&1["metric"] == "frameshift.command.duration.ms"))
  end

  test "audit pages remain correlated and redact subject and private detail", context do
    command_id = "audit-command-1"
    digest = Digest.sha256("canonical command")
    assert {:ok, :execute} = Library.claim_command(context.library, command_id, digest)
    assert :ok = Library.complete_command(context.library, command_id, digest, :ok)

    assert %{"ok" => true, "diagnostics" => first_page} =
             request(context.path, "audit", %{"limit" => 1})

    assert first_page["hasMore"]
    [latest] = first_page["entries"]
    assert latest["operation"] == "command.completed"
    assert latest["correlationId"] == Digest.sha256(command_id)
    refute Map.has_key?(latest, "subjectDigest")
    refute Map.has_key?(latest, "detail_json")

    assert %{"ok" => true, "diagnostics" => second_page} =
             request(context.path, "audit", %{"limit" => 1, "cursor" => first_page["nextCursor"]})

    assert hd(second_page["entries"])["operation"] == "command.claimed"
  end

  test "rejects mutation operations and malformed page requests", context do
    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request(context.path, "command")

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request(context.path, "audit", %{"limit" => 1_000})

    assert %File.Stat{mode: mode} = File.lstat!(context.path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "metric reads remain available while the collector restarts", context do
    GenServer.stop(context.metrics)

    assert %{"ok" => true, "diagnostics" => %{"coverage" => %{"available" => false}}} =
             request(context.path, "metrics")

    assert %{"ok" => true, "diagnostics" => %{"collector" => %{"available" => false}}} =
             request(context.path, "health")
  end

  test "malformed rollups cannot crash the SQLite owner", context do
    assert {:error, :invalid_metric_batch} = Library.write_metric_rollups(context.library, [%{}])

    assert {:error, :invalid_metric_batch} =
             Library.write_metric_rollups(context.library, :invalid)

    assert Process.alive?(context.library)
    assert %{"ok" => true} = request(context.path, "health")
  end

  test "a stalled diagnostic client does not block another read", context do
    {:ok, stalled} = :gen_tcp.connect({:local, context.path}, 0, [:binary, active: false])
    :ok = :gen_tcp.send(stalled, <<64::unsigned-big-32>>)

    assert %{"ok" => true} = request(context.path, "health")
    :gen_tcp.close(stalled)
  end

  test "a symlinked diagnostics directory is rejected without changing its target", context do
    parent = Path.dirname(context.path)
    target = Path.join(parent, "target")
    link = Path.join(parent, "linked")
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)
    :ok = File.ln_s(target, link)

    result =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        DiagnosticsServer.start_link(
          path: Path.join(link, "other.sock"),
          library: context.library,
          metrics: context.metrics,
          name: nil
        )
      end)

    assert {:error, :unsafe_diagnostics_directory} = Task.await(result)

    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o755
  end

  defp request(path, operation, extra \\ %{}) do
    request_id = "diag-#{System.unique_integer([:positive])}"

    payload =
      %{"version" => 1, "requestId" => request_id, "operation" => operation}
      |> Map.merge(extra)
      |> RFC8785.encode!()

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [
        :binary,
        {:packet, 4},
        {:packet_size, 256 * 1024},
        {:active, false}
      ])

    :ok = :gen_tcp.send(socket, payload)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    decoded = Jason.decode!(response)
    assert decoded["requestId"] == request_id or decoded["requestId"] == nil
    decoded
  end
end
