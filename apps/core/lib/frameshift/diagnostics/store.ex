defmodule Frameshift.Diagnostics.Store do
  @moduledoc """
  Persists audit facts and bounded metric rollups through the library owner.

  `record_audit/4` joins redacted attribution to the caller's domain transaction.
  `audit_page/3`, `metric_page/3` and `health/1` return bounded read projections,
  with stable pagination and identifier-free health gauges rather than the raw
  SQLite connection or arbitrary SQL access.

  Linux command claim/completion facts may include a validated SHA-256 `actorId`
  derived from the policy and authenticated UID. This permits correlation without
  exposing raw account IDs, usernames, PIDs or group lists; a hash of a numeric
  account is not anonymization. Private token commands omit that actor field.

  ## Metric retention

  `validate_rollups/1` checks batch shape/count and the versioned catalog before
  writes. `merge_rollups/3` combines completed buckets under the caller's transaction.
  Page-allocation measurement and budget enforcement include table/index storage
  and prune oldest metric rows to keep the declared retention boundary.

  Only `Frameshift.Library` supplies the private connection and writer context.
  This module owns neither an independent pool nor IPC mutation dispatch.
  Audit custody and metric aggregation have different semantics: missing metrics
  cannot erase an audit fact, and telemetry cannot manufacture domain success.
  """

  @audit_detail_keys ~w(kind outcome revision sourceKind actorId)
  @audit_kinds ~w(composition generation succeeded failed push reconcile)
  @audit_outcomes ~w(started displayed pending unknown failed)
  @audit_sources ~w(import generated)
  @maximum_page 100
  @maximum_rows 20_000
  @metric_page_budget_bytes 32 * 1024 * 1024

  alias Frameshift.Diagnostics.Catalog
  alias Frameshift.Digest

  @doc "Writes a redacted audit fact under the caller's domain transaction."
  @spec record_audit(pid(), String.t(), String.t() | nil, map()) :: :ok
  def record_audit(connection, operation, subject_digest, details) do
    correlation_id =
      case Map.get(details, "commandId") || Map.get(details, "requestId") do
        value when is_binary(value) and byte_size(value) in 1..64 -> Digest.sha256(value)
        _ -> nil
      end

    Exqlite.query!(
      connection,
      """
      INSERT INTO audit_entries(
        operation, subject_digest, detail_json, occurred_at_ms, correlation_id, attempt_id
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        operation,
        subject_digest,
        details |> safe_audit_details() |> RFC8785.encode!(),
        System.os_time(:millisecond),
        correlation_id,
        safe_attempt_id(Map.get(details, "attemptId"))
      ]
    )

    :ok
  end

  defp safe_audit_details(details) do
    details
    |> Map.take(@audit_detail_keys)
    |> Enum.reduce(%{}, fn {key, value}, safe ->
      if allowed_detail?(key, value), do: Map.put(safe, key, value), else: safe
    end)
  end

  defp allowed_detail?("kind", value), do: value in @audit_kinds
  defp allowed_detail?("outcome", value), do: value in @audit_outcomes
  defp allowed_detail?("sourceKind", value), do: value in @audit_sources
  defp allowed_detail?("revision", value), do: is_integer(value) and value in 1..1_000_000_000
  defp allowed_detail?("actorId", value), do: Digest.valid_sha256?(value)

  defp safe_attempt_id(value) when is_binary(value) and byte_size(value) == 32 do
    if String.match?(value, ~r/\A[0-9a-f]{32}\z/), do: value, else: nil
  end

  defp safe_attempt_id(_), do: nil

  @doc "Rejects malformed or unbounded metric batches before opening a write transaction."
  @spec validate_rollups(term()) :: :ok | {:error, :invalid_metric_batch}
  def validate_rollups(rows) when is_list(rows) do
    if length(rows) <= 2_000 and Enum.all?(rows, &Catalog.valid_rollup?/1),
      do: :ok,
      else: {:error, :invalid_metric_batch}
  end

  def validate_rollups(_), do: {:error, :invalid_metric_batch}

  @doc "Returns a descending, stable audit page with private fields removed."
  @spec audit_page(pid(), non_neg_integer() | nil, pos_integer()) ::
          map() | {:error, :invalid_diagnostics_query}
  def audit_page(connection, cursor, limit)
      when (is_nil(cursor) or (is_integer(cursor) and cursor >= 0)) and is_integer(limit) and
             limit in 1..@maximum_page do
    result =
      Exqlite.query!(
        connection,
        """
        SELECT id, operation, detail_json, correlation_id, attempt_id, occurred_at_ms
        FROM audit_entries
        WHERE (? IS NULL OR id < ?)
        ORDER BY id DESC LIMIT ?
        """,
        [cursor, cursor, limit + 1]
      )

    rows = Enum.take(result.rows, limit)

    entries =
      Enum.map(rows, fn [id, operation, details_json, correlation_id, attempt_id, occurred_at_ms] ->
        details =
          details_json
          |> Jason.decode!()
          |> Map.take(@audit_detail_keys)

        %{
          "id" => id,
          "operation" => operation,
          "detail" => details,
          "correlationId" => correlation_id,
          "attemptId" => attempt_id,
          "occurredAtMs" => occurred_at_ms
        }
      end)

    has_more = length(result.rows) > limit

    %{
      "entries" => entries,
      "nextCursor" => if(has_more, do: List.last(entries)["id"], else: nil),
      "hasMore" => has_more
    }
  end

  def audit_page(_, _, _), do: {:error, :invalid_diagnostics_query}

  @doc "Returns a bounded recent metric page from committed rollups."
  @spec metric_page(pid(), non_neg_integer() | nil, pos_integer()) :: map() | {:error, atom()}
  def metric_page(connection, cursor, limit)
      when (is_nil(cursor) or (is_integer(cursor) and cursor >= 0)) and is_integer(limit) and
             limit in 1..@maximum_page do
    result =
      Exqlite.query!(
        connection,
        """
        SELECT rowid, metric, bucket_ms, granularity, dimensions_json,
               sample_count, value_sum, value_min, value_max, histogram_json
        FROM metric_rollups
        WHERE (? IS NULL OR rowid < ?)
        ORDER BY rowid DESC LIMIT ?
        """,
        [cursor, cursor, limit + 1]
      )

    entries =
      result.rows
      |> Enum.take(limit)
      |> Enum.map(fn [
                       id,
                       metric,
                       bucket_ms,
                       granularity,
                       dimensions_json,
                       count,
                       sum,
                       min,
                       max,
                       histogram_json
                     ] ->
        %{
          "id" => id,
          "metric" => metric,
          "bucketMs" => bucket_ms,
          "granularity" => granularity,
          "dimensions" => Jason.decode!(dimensions_json),
          "count" => count,
          "sum" => sum,
          "min" => min,
          "max" => max,
          "histogram" => Jason.decode!(histogram_json)
        }
      end)

    has_more = length(result.rows) > limit

    %{
      "entries" => entries,
      "nextCursor" => if(has_more, do: List.last(entries)["id"], else: nil),
      "hasMore" => has_more
    }
  end

  def metric_page(_, _, _), do: {:error, :invalid_diagnostics_query}

  @doc "Returns small, identifier-free gauges from authoritative state."
  @spec health(pid()) :: map()
  def health(connection) do
    counts =
      Exqlite.query!(
        connection,
        """
        SELECT
          (SELECT count(*) FROM frame_outboxes),
          (SELECT count(*) FROM frame_direct_deliveries WHERE status = 'pending'),
          (SELECT count(*) FROM command_receipts WHERE status = 'pending'),
          (SELECT count(*) FROM audit_entries),
          (SELECT count(*) FROM metric_rollups)
        """
      ).rows

    [[outboxes, direct_pending, command_pending, audit_count, metric_count]] = counts
    page_measurement = metric_allocated_bytes(connection)

    %{
      "pendingPull" => outboxes,
      "pendingPush" => direct_pending,
      "unknownCommands" => command_pending,
      "auditEntries" => audit_count,
      "metricRollups" => metric_count,
      "metricAllocatedBytes" =>
        case page_measurement do
          {:ok, bytes} -> bytes
          {:error, _} -> nil
        end,
      "metricPageMeasurementAvailable" => match?({:ok, _}, page_measurement),
      "metricPageBudgetBytes" => @metric_page_budget_bytes
    }
  end

  @doc "Merges a bounded batch of completed metric buckets under the caller's transaction."
  @spec merge_rollups(pid(), [map()], non_neg_integer()) :: :ok
  def merge_rollups(connection, rows, now_ms) when is_list(rows) and length(rows) <= 2_000 do
    Enum.each(rows, &merge_rollup(connection, &1))

    Exqlite.query!(
      connection,
      "DELETE FROM metric_rollups WHERE (granularity = 'minute' AND bucket_ms < ?) OR (granularity = 'hour' AND bucket_ms < ?)",
      [now_ms - 86_400_000, now_ms - 2_592_000_000]
    )

    count =
      connection
      |> Exqlite.query!("SELECT count(*) FROM metric_rollups")
      |> Map.fetch!(:rows)
      |> then(fn [[value]] -> value end)

    if count > @maximum_rows do
      Exqlite.query!(
        connection,
        "DELETE FROM metric_rollups WHERE rowid IN (SELECT rowid FROM metric_rollups ORDER BY bucket_ms ASC, rowid ASC LIMIT ?)",
        [count - @maximum_rows]
      )
    end

    enforce_metric_page_budget(connection, @metric_page_budget_bytes)
    :ok
  end

  @doc "Measures allocated SQLite pages for the metric table and all its indexes."
  @spec metric_allocated_bytes(pid()) ::
          {:ok, non_neg_integer()} | {:error, :metric_page_measurement_unavailable}
  def metric_allocated_bytes(connection) do
    case Exqlite.query(connection, """
         SELECT COALESCE(SUM(pgsize), 0)
         FROM dbstat
         WHERE name = 'metric_rollups'
            OR name IN (SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'metric_rollups')
         """) do
      {:ok, %Exqlite.Result{rows: [[bytes]]}} when is_integer(bytes) and bytes >= 0 ->
        {:ok, bytes}

      _ ->
        {:error, :metric_page_measurement_unavailable}
    end
  end

  @doc "Prunes oldest metric rows until their active SQLite pages fit the byte budget."
  @spec enforce_metric_page_budget(pid(), pos_integer()) :: :ok
  def enforce_metric_page_budget(connection, budget_bytes)
      when is_integer(budget_bytes) and budget_bytes > 0 do
    trim_metric_pages(connection, budget_bytes)
  end

  defp trim_metric_pages(connection, budget_bytes) do
    case metric_allocated_bytes(connection) do
      {:ok, bytes} when bytes > budget_bytes ->
        Exqlite.query!(
          connection,
          "DELETE FROM metric_rollups WHERE rowid IN (SELECT rowid FROM metric_rollups ORDER BY bucket_ms ASC, rowid ASC LIMIT 1000)"
        )

        case Exqlite.query!(connection, "SELECT changes()").rows do
          [[0]] -> Exqlite.rollback(connection, :metric_page_budget_unenforceable)
          [[_]] -> trim_metric_pages(connection, budget_bytes)
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Exqlite.rollback(connection, reason)
    end
  end

  defp merge_rollup(connection, row) do
    dimensions_json = RFC8785.encode!(row.dimensions)

    existing =
      Exqlite.query!(
        connection,
        """
        SELECT sample_count, value_sum, value_min, value_max, histogram_json
        FROM metric_rollups
        WHERE metric = ? AND bucket_ms = ? AND granularity = ? AND dimensions_json = ?
        """,
        [row.metric, row.bucket_ms, row.granularity, dimensions_json]
      ).rows

    merged =
      case existing do
        [[count, sum, min, max, histogram_json]] ->
          %{
            count: count + row.count,
            sum: sum + row.sum,
            min: Kernel.min(min, row.min),
            max: Kernel.max(max, row.max),
            histogram: merge_histograms(Jason.decode!(histogram_json), row.histogram)
          }

        [] ->
          row
      end

    Exqlite.query!(
      connection,
      """
      INSERT INTO metric_rollups(
        metric, bucket_ms, granularity, dimensions_json, sample_count,
        value_sum, value_min, value_max, histogram_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(metric, bucket_ms, granularity, dimensions_json) DO UPDATE SET
        sample_count = excluded.sample_count,
        value_sum = excluded.value_sum,
        value_min = excluded.value_min,
        value_max = excluded.value_max,
        histogram_json = excluded.histogram_json
      """,
      [
        row.metric,
        row.bucket_ms,
        row.granularity,
        dimensions_json,
        merged.count,
        merged.sum,
        merged.min,
        merged.max,
        RFC8785.encode!(merged.histogram)
      ]
    )
  end

  defp merge_histograms(left, right) when length(left) == length(right) do
    Enum.zip_with(left, right, &(&1 + &2))
  end
end
