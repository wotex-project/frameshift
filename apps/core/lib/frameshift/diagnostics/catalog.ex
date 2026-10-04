defmodule Frameshift.Diagnostics.Catalog do
  @moduledoc """
  Defines versioned native telemetry events, measurements and finite dimensions.

  `events/0` lists owned events and `metrics/0` exposes their Telemetry.Metrics
  representations. `samples/3` accepts bounded finite observations and reduces
  enum values to declared dimensions, with unknown values collapsed to `other`.
  Dynamic frame/content/correlation identifiers are not metric labels.

  ## Persistent meaning

  `describe/0` supplies the machine-readable catalog used to interpret rollups;
  `valid_rollup?/1` checks a completed aggregate before storage. Units, bounds,
  aggregation and schema revision belong to this catalog, not an emitter-chosen
  metadata map. Invalid input produces no admitted samples.

  `Frameshift.Diagnostics.Metrics` owns collection and aggregation, and
  `Frameshift.Diagnostics.Store` writes validated rollups under the library
  writer. Metrics establish reported coverage/loss and observed operation counts;
  they do not replace durable command/audit receipts or prove display completion.
  """

  @duration_buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]

  @specs [
    %{
      name: "frameshift.command.completed.count",
      event: [:frameshift, :command, :completed],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{outcome: ~w(succeeded failed replay unknown other)},
      buckets: []
    },
    %{
      name: "frameshift.command.duration.ms",
      event: [:frameshift, :command, :completed],
      measure: :duration_ms,
      kind: :distribution,
      unit: :millisecond,
      dimensions: %{outcome: ~w(succeeded failed replay unknown other)},
      buckets: @duration_buckets
    },
    %{
      name: "frameshift.qualification.decision.count",
      event: [:frameshift, :qualification, :decision],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{
        stage: ~w(candidate admission activation cohort work result other),
        outcome: ~w(succeeded refused other)
      },
      buckets: []
    },
    %{
      name: "frameshift.delivery.intent.count",
      event: [:frameshift, :delivery, :intent],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{mode: ~w(push pull other)},
      buckets: []
    },
    %{
      name: "frameshift.delivery.attempt.count",
      event: [:frameshift, :delivery, :attempt],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{
        mode: ~w(push reconcile other),
        outcome: ~w(displayed pending unknown failed other)
      },
      buckets: []
    },
    %{
      name: "frameshift.delivery.confirmed.duration.ms",
      event: [:frameshift, :delivery, :confirmed],
      measure: :duration_ms,
      kind: :distribution,
      unit: :millisecond,
      dimensions: %{mode: ~w(push pull other)},
      buckets: @duration_buckets
    },
    %{
      name: "frameshift.outbox.exchange.count",
      event: [:frameshift, :outbox, :exchange],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{
        route: ~w(manifest asset playlist ack invalid other),
        outcome: ~w(succeeded empty conflict unavailable rejected other)
      },
      buckets: []
    },
    %{
      name: "frameshift.outbox.listener.count",
      event: [:frameshift, :outbox, :listener],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{state: ~w(started stopped unavailable other)},
      buckets: []
    },
    %{
      name: "frameshift.outbox.exchange.duration.ms",
      event: [:frameshift, :outbox, :exchange],
      measure: :duration_ms,
      kind: :distribution,
      unit: :millisecond,
      dimensions: %{
        route: ~w(manifest asset playlist ack invalid other),
        outcome: ~w(succeeded empty conflict unavailable rejected other)
      },
      buckets: @duration_buckets
    },
    %{
      name: "frameshift.render.duration.ms",
      event: [:frameshift, :render, :completed],
      measure: :duration_ms,
      kind: :distribution,
      unit: :millisecond,
      dimensions: %{outcome: ~w(succeeded failed cache_hit other)},
      buckets: @duration_buckets
    },
    %{
      name: "frameshift.storage.transaction.duration.ms",
      event: [:frameshift, :storage, :transaction],
      measure: :duration_ms,
      kind: :distribution,
      unit: :millisecond,
      dimensions: %{outcome: ~w(succeeded failed other)},
      buckets: @duration_buckets
    },
    %{
      name: "frameshift.diagnostics.dropped.count",
      event: [:frameshift, :diagnostics, :dropped],
      measure: :count,
      kind: :sum,
      unit: :count,
      dimensions: %{signal: ~w(metric log other)},
      buckets: []
    }
  ]

  @doc "Returns all portable telemetry event names."
  @spec events() :: [list(atom())]
  def events, do: @specs |> Enum.map(& &1.event) |> Enum.uniq()

  @doc "Returns the versioned, machine-readable meaning of persisted rollups."
  @spec describe() :: map()
  def describe do
    %{
      "version" => 2,
      "retentionMs" => %{"minute" => 86_400_000, "hour" => 2_592_000_000},
      "metrics" =>
        Enum.map(@specs, fn spec ->
          %{
            "name" => spec.name,
            "owner" => spec.event |> Enum.at(1) |> Atom.to_string(),
            "event" => Enum.join(spec.event, "."),
            "measurement" => Atom.to_string(spec.measure),
            "aggregation" => Atom.to_string(spec.kind),
            "unit" => Atom.to_string(spec.unit),
            "dimensions" =>
              Map.new(spec.dimensions, fn {key, allowed} -> {Atom.to_string(key), allowed} end),
            "upperBounds" => spec.buckets
          }
        end)
    }
  end

  @doc "Returns the Telemetry.Metrics definitions used by the local reporter."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    Enum.map(@specs, fn spec ->
      options = [
        event_name: spec.event,
        measurement: spec.measure,
        tags: Map.keys(spec.dimensions),
        unit: spec.unit
      ]

      case spec.kind do
        :sum -> Telemetry.Metrics.sum(spec.name, options)
        :distribution -> Telemetry.Metrics.distribution(spec.name, options)
      end
    end)
  end

  @doc "Extracts finite, bounded samples and normalized dimensions from an event."
  @spec samples(list(atom()), map(), map()) :: [map()]
  def samples(event, measurements, metadata) when is_map(measurements) and is_map(metadata) do
    @specs
    |> Enum.filter(&(&1.event == event))
    |> Enum.flat_map(&sample_for(&1, measurements, metadata))
  end

  def samples(_, _, _), do: []

  @doc "Checks a completed rollup against the versioned catalog before persistence."
  @spec valid_rollup?(term()) :: boolean()
  def valid_rollup?(%{metric: metric} = row) do
    case Enum.find(@specs, &(&1.name == metric)) do
      nil -> false
      spec -> valid_rollup_for_spec?(row, spec)
    end
  end

  def valid_rollup?(_), do: false

  defp valid_rollup_for_spec?(row, spec) do
    valid_bucket?(Map.get(row, :bucket_ms), Map.get(row, :granularity)) and
      valid_dimensions?(Map.get(row, :dimensions), spec.dimensions) and
      valid_measurement?(row) and
      valid_histogram?(Map.get(row, :histogram), spec.buckets, Map.get(row, :count))
  end

  defp valid_measurement?(%{count: count, sum: sum, min: min, max: max}) do
    is_integer(count) and count in 1..1_000_000_000 and
      finite_number?(sum) and finite_number?(min) and finite_number?(max) and
      min <= max and sum <= 1.0e21
  end

  defp valid_measurement?(_), do: false

  defp valid_bucket?(bucket_ms, granularity) when is_integer(bucket_ms) do
    width =
      case granularity do
        "minute" -> 60_000
        "hour" -> 3_600_000
        _ -> nil
      end

    not is_nil(width) and bucket_ms >= 0 and bucket_ms <= 1_000_000_000_000_000 and
      rem(bucket_ms, width) == 0
  end

  defp valid_bucket?(_, _), do: false

  defp valid_dimensions?(dimensions, expected) when is_map(dimensions) do
    map_size(dimensions) == map_size(expected) and
      Enum.all?(expected, fn {key, allowed} ->
        Map.get(dimensions, Atom.to_string(key)) in allowed
      end)
  end

  defp valid_dimensions?(_, _), do: false

  defp valid_histogram?(histogram, buckets, count) when is_list(histogram) do
    length(histogram) == length(buckets) + 1 and
      Enum.all?(histogram, &(is_integer(&1) and &1 >= 0)) and Enum.sum(histogram) == count
  end

  defp valid_histogram?(_, _, _), do: false

  defp finite_number?(value) when is_integer(value), do: value >= 0 and value <= 1.0e21
  defp finite_number?(value) when is_float(value), do: value >= 0 and value <= 1.0e21
  defp finite_number?(_), do: false

  defp sample_for(spec, measurements, metadata) do
    value = Map.get(measurements, spec.measure)

    if valid_value?(value) do
      dimensions = Map.new(spec.dimensions, &dimension(&1, metadata))

      [
        %{
          metric: spec.name,
          value: value,
          dimensions: dimensions,
          buckets: spec.buckets
        }
      ]
    else
      []
    end
  end

  defp dimension({key, allowed}, metadata) do
    candidate =
      case Map.get(metadata, key) do
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) and byte_size(value) <= 64 -> value
        _ -> "other"
      end

    {Atom.to_string(key), if(candidate in allowed, do: candidate, else: "other")}
  end

  defp valid_value?(value) when is_integer(value), do: value >= 0 and value <= 1_000_000_000_000

  defp valid_value?(value) when is_float(value) do
    value >= 0 and value <= 1_000_000_000_000
  end

  defp valid_value?(_), do: false
end
