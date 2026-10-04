defmodule Frameshift.Diagnostics.Metrics do
  @moduledoc """
  Collects bounded native telemetry and persists aggregate rollups.

  Start the reporter after `Frameshift.Library`. Its synchronous telemetry
  callback projects events through `Frameshift.Diagnostics.Catalog` before enqueueing
  bounded samples; aggregation and SQLite writes occur in the supervised reporter,
  not the event emitter. Queue and pending-series limits prevent unbounded growth.

  ## Coverage, flush and restart

  `status/1` exposes start/event/flush times, queue/pending counts, dropped events
  and flush failures without waiting for storage. `flush/1` attempts a bounded
  batch through the library writer; periodic flush and retention maintenance use
  the same path. Failed flushes remain visible rather than pretending collection
  was complete or discarding authoritative domain records.

  Collector restart begins a new observation interval; persisted minute/hour
  rollups retain their catalog meaning. Telemetry loss must remain explicit.
  The reporter is not a domain receipt journal, and disabled or unavailable
  collection cannot grant or revoke frame control authority.
  """

  use GenServer

  alias Frameshift.Diagnostics.Catalog
  alias Frameshift.Library

  @queue_limit 10_000
  @pending_limit 2_000
  @flush_interval_ms 10_000

  defmodule State do
    @moduledoc """
    Holds transient metric buckets and collector coverage for one reporter.

    The state keeps the attached handler ID, library server, atomic queue/loss
    counters, pending series and event/flush timestamps. Failed flushes remain
    visible alongside uncommitted buckets; a pending observation is not durable
    until the library confirms its rollup transaction.

    ## Owner and lifetime

    Only `Frameshift.Diagnostics.Metrics` manages this value. Reporter restart
    creates a new collection interval while already committed database rollups
    retain their catalog meaning. Raw event metadata and private frame/artwork
    identifiers do not belong in these aggregates.
    """

    @type t :: %__MODULE__{
            handler_id: String.t(),
            library: GenServer.server(),
            dropped: reference(),
            queued: reference(),
            pending: map(),
            started_at_ms: integer(),
            last_dropped: non_neg_integer(),
            last_event_at_ms: integer() | nil,
            last_flushed_at_ms: integer() | nil,
            flush_failures: non_neg_integer()
          }

    @enforce_keys [:handler_id, :library, :dropped, :queued]
    defstruct [
      :handler_id,
      :library,
      :dropped,
      :queued,
      pending: %{},
      started_at_ms: nil,
      last_dropped: 0,
      last_event_at_ms: nil,
      last_flushed_at_ms: nil,
      flush_failures: 0
    ]
  end

  @doc "Starts the supervised local reporter after the SQLite owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Reports collector coverage and loss without waiting for a database flush."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Flushes pending aggregates; intended for lifecycle and verification."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @impl true
  def init(options) do
    library = Keyword.get(options, :library, Library)
    handler_id = "frameshift-local-metrics-#{System.unique_integer([:positive, :monotonic])}"
    dropped = :atomics.new(1, signed: false)
    queued = :atomics.new(1, signed: false)

    :ok =
      :telemetry.attach_many(
        handler_id,
        Catalog.events(),
        &__MODULE__.handle_event/4,
        %{target: self(), dropped: dropped, queued: queued, queue_limit: @queue_limit}
      )

    Process.send_after(self(), :flush, @flush_interval_ms)
    send(self(), :maintenance)

    {:ok,
     %State{
       handler_id: handler_id,
       library: library,
       dropped: dropped,
       queued: queued,
       started_at_ms: System.os_time(:millisecond)
     }}
  end

  @doc "Telemetry callback: sends bounded work to the supervised reporter."
  @spec handle_event(list(atom()), map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, context) do
    case Catalog.samples(event, measurements, metadata) do
      [] ->
        :ok

      samples ->
        enqueue_samples(samples, context)
    end
  end

  defp enqueue_samples(samples, %{
         target: target,
         dropped: dropped,
         queued: queued,
         queue_limit: limit
       }) do
    if reserve_slot(queued, limit) do
      send(target, {:samples, samples})
    else
      :atomics.add(dropped, 1, 1)
    end

    :ok
  end

  defp reserve_slot(queued, limit) do
    current = :atomics.get(queued, 1)

    cond do
      current >= limit -> false
      :atomics.compare_exchange(queued, 1, current, current + 1) == :ok -> true
      true -> reserve_slot(queued, limit)
    end
  end

  @impl true
  def handle_call(:status, _, state) do
    {:reply,
     %{
       "startedAtMs" => state.started_at_ms,
       "lastEventAtMs" => state.last_event_at_ms,
       "lastFlushedAtMs" => state.last_flushed_at_ms,
       "flushFailures" => state.flush_failures,
       "queuedEvents" => :atomics.get(state.queued, 1),
       "pendingSeries" => map_size(state.pending),
       "droppedEvents" => :atomics.get(state.dropped, 1)
     }, state}
  end

  def handle_call(:flush, _, state) do
    {result, next_state} = flush_pending(state)
    {:reply, result, next_state}
  end

  @impl true
  def handle_info({:samples, samples}, state) do
    :atomics.add_get(state.queued, 1, -1)
    now_ms = System.os_time(:millisecond)

    next =
      Enum.reduce(samples, state, fn sample, accumulator ->
        add_sample(accumulator, sample, now_ms)
      end)

    {:noreply, %{next | last_event_at_ms: now_ms}}
  end

  def handle_info(:flush, state) do
    {_, next_state} = flush_pending(state)
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:noreply, next_state}
  end

  def handle_info(:maintenance, state) do
    next_state =
      case Library.write_metric_rollups(state.library, []) do
        :ok -> state
        {:error, _} -> %{state | flush_failures: state.flush_failures + 1}
      end

    {:noreply, next_state}
  catch
    :exit, _ -> {:noreply, %{state | flush_failures: state.flush_failures + 1}}
  end

  @impl true
  def terminate(_, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  defp add_sample(state, sample, now_ms) do
    Enum.reduce([{"minute", 60_000}, {"hour", 3_600_000}], state, fn {granularity, width},
                                                                     current ->
      bucket_ms = div(now_ms, width) * width
      key = {sample.metric, bucket_ms, granularity, sample.dimensions}

      cond do
        Map.has_key?(current.pending, key) ->
          %{current | pending: Map.update!(current.pending, key, &accumulate(&1, sample))}

        map_size(current.pending) < @pending_limit ->
          row = %{
            metric: sample.metric,
            bucket_ms: bucket_ms,
            granularity: granularity,
            dimensions: sample.dimensions,
            count: 0,
            sum: 0.0,
            min: sample.value * 1.0,
            max: sample.value * 1.0,
            histogram: List.duplicate(0, length(sample.buckets) + 1)
          }

          %{current | pending: Map.put(current.pending, key, accumulate(row, sample))}

        true ->
          :atomics.add(current.dropped, 1, 1)
          current
      end
    end)
  end

  defp accumulate(row, sample) do
    index = Enum.find_index(sample.buckets, &(sample.value <= &1)) || length(sample.buckets)

    %{
      row
      | count: row.count + 1,
        sum: row.sum + sample.value,
        min: min(row.min, sample.value),
        max: max(row.max, sample.value),
        histogram: List.update_at(row.histogram, index, &(&1 + 1))
    }
  end

  defp flush_pending(state) do
    state = if map_size(state.pending) == 0, do: collect_drop_count(state), else: state

    if map_size(state.pending) == 0 do
      {:ok, state}
    else
      result = Library.write_metric_rollups(state.library, Map.values(state.pending))

      case result do
        :ok ->
          next =
            state
            |> Map.put(:pending, %{})
            |> Map.put(:last_flushed_at_ms, System.os_time(:millisecond))
            |> collect_drop_count()

          {:ok, next}

        {:error, reason} ->
          {{:error, reason}, %{state | flush_failures: state.flush_failures + 1}}
      end
    end
  catch
    :exit, reason -> {{:error, reason}, %{state | flush_failures: state.flush_failures + 1}}
  end

  defp collect_drop_count(state) do
    total = :atomics.get(state.dropped, 1)
    delta = total - state.last_dropped

    if delta > 0 do
      sample = %{
        metric: "frameshift.diagnostics.dropped.count",
        value: delta,
        dimensions: %{"signal" => "metric"},
        buckets: []
      }

      state
      |> add_sample(sample, System.os_time(:millisecond))
      |> Map.put(:last_dropped, total)
    else
      state
    end
  end
end
