defmodule FrameshiftPlatform.Telemetry.Reporter do
  @moduledoc """
  Aggregates the platform metric catalog into fixed Prometheus buckets.

  The supervised reporter owns a named registry and telemetry attachment.
  Handlers project finite catalog dimensions directly into counters, gauges and
  histograms without sending one process message per event or retaining samples.
  Raw event metadata is examined for tags and then discarded.

  ## Lifecycle and failure

  Startup clears the process-local registry, declares the current catalog and
  samples VM state. Sampling repeats every ten seconds; restart resets aggregates
  and the start timestamp. `scrape/0` returns text or `{:error, :unavailable}` if
  the owner cannot answer within its bounded call.

  Invalid, nonfinite, negative or oversized observations increment a rejection
  counter rather than escaping into new labels. Termination detaches the handler.
  The registry is operational telemetry and never owns catalog receipts or audit
  truth; `FrameshiftPlatformWeb.MetricsController` independently protects export.
  """

  use GenServer

  alias FrameshiftPlatform.Telemetry, as: Catalog
  alias Telemetry.Metrics.{Counter, Distribution, LastValue}

  @registry :frameshift_platform
  @handler {__MODULE__, :catalog_v2}
  @rejected "frameshift_platform_telemetry_rejected_total"
  @sample [:frameshift_platform, :collector, :sample]
  @period 10_000
  @maximum 9_007_199_254_740_991

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec scrape() :: {:ok, binary()} | {:error, :unavailable}
  def scrape do
    GenServer.call(__MODULE__, :scrape, 1_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec registry() :: atom()
  def registry, do: @registry

  @impl true
  def init(_) do
    :telemetry.detach(@handler)
    :prometheus_registry.clear(@registry)
    metrics = Catalog.metrics()
    Enum.each(metrics, &declare/1)

    :prometheus_counter.declare(
      registry: @registry,
      name: @rejected,
      help: "Rejected metric observations."
    )

    :ok =
      :telemetry.attach_many(
        @handler,
        Enum.uniq(Enum.map(metrics, & &1.event_name)),
        &__MODULE__.handle_event/4,
        %{
          owner: self(),
          metrics: Enum.group_by(metrics, & &1.event_name)
        }
      )

    started = System.system_time(:millisecond) / 1_000
    sample(started)
    Process.send_after(self(), :sample, @period)
    {:ok, started}
  end

  @impl true
  def handle_call(:scrape, _, started) do
    {:reply, {:ok, :prometheus_text_format.format(@registry)}, started}
  rescue
    _ -> {:reply, {:error, :unavailable}, started}
  end

  @impl true
  def handle_info(:sample, started) do
    sample(started)
    Process.send_after(self(), :sample, @period)
    {:noreply, started}
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach(@handler)

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    if Process.alive?(config.owner) do
      Enum.each(Map.get(config.metrics, event, []), &observe(&1, measurements, metadata))
    end

    :ok
  end

  defp declare(metric) do
    opts = [
      registry: @registry,
      name: name(metric),
      help: metric.description,
      labels: metric.tags,
      duration_unit: false
    ]

    declare_type(metric, opts)
  end

  defp declare_type(%Counter{}, opts), do: :prometheus_counter.declare(opts)
  defp declare_type(%LastValue{}, opts), do: :prometheus_gauge.declare(opts)

  defp declare_type(%Distribution{reporter_options: options}, opts) do
    :prometheus_histogram.declare(Keyword.put(opts, :buckets, Keyword.fetch!(options, :buckets)))
  end

  defp observe(metric, measurements, metadata) do
    if is_nil(metric.keep) or metric.keep.(metadata), do: record(metric, measurements, metadata)
  rescue
    _ -> reject()
  catch
    _, _ -> reject()
  end

  defp record(metric, measurements, metadata) do
    tags = Enum.map(metric.tags, &Map.fetch!(metric.tag_values.(metadata), &1))
    value = valid_measurement(metric, measurements)
    maximum = Keyword.get(metric.reporter_options, :maximum, @maximum)

    if is_number(value) and value >= 0 and value <= maximum do
      update(metric, tags, value)
    else
      reject()
    end
  end

  defp valid_measurement(%Distribution{} = metric, values) do
    native = Map.get(values, Keyword.fetch!(metric.reporter_options, :native_measurement))
    if is_integer(native), do: measurement(metric, values)
  end

  defp valid_measurement(%LastValue{unit: unit} = metric, values) when unit in [:byte, :unit] do
    value = measurement(metric, values)
    if is_integer(value), do: value
  end

  defp valid_measurement(metric, values), do: measurement(metric, values)

  defp measurement(%Counter{}, _), do: 1
  defp measurement(%{measurement: field}, values) when is_atom(field), do: Map.get(values, field)
  defp measurement(%{measurement: fun}, values) when is_function(fun, 1), do: fun.(values)

  defp update(%Counter{} = metric, tags, _),
    do: :prometheus_counter.inc(@registry, name(metric), tags, 1)

  defp update(%LastValue{} = metric, tags, value),
    do: :prometheus_gauge.set(@registry, name(metric), tags, value)

  defp update(%Distribution{} = metric, tags, value) do
    :prometheus_histogram.observe(@registry, name(metric), tags, value)
  end

  defp name(metric), do: Enum.join(metric.name, "_")

  defp reject do
    :prometheus_counter.inc(@registry, @rejected, [], 1)
  catch
    _, _ -> :ok
  end

  defp sample(started) do
    :telemetry.execute(@sample, %{
      memory_bytes: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue),
      started_seconds: started,
      sampled_seconds: System.system_time(:millisecond) / 1_000
    })
  end
end
