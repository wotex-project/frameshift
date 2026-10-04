defmodule Frameshift.Library.Storage do
  @moduledoc """
  Accounts registered object bytes and admits content under a durable local budget.

  The Library's serialized owner calls `admit/2` before immutable master or
  artifact placement. Active and recoverable-trash objects both count once by
  digest; reuse consumes no new allowance and the content store still verifies
  the actual bytes. Budget pressure never deletes artwork or changes delivery.

  ## Configuration and recovery

  `read/1` returns bounded, path-free usage and the configuration revision.
  `update/3` checks that revision and commits the limit with a redacted audit fact
  in one writer transaction. A lower limit can leave existing usage over budget
  while reads, metadata edits and restore remain usable. Invalid persisted
  configuration refuses rather than silently selecting a replacement value.

  The initial limit is 20 GiB, with explicit limits from 1 MiB to 1 TiB.
  Accounting covers registered object bytes, not filesystem free space, SQLite,
  logs, transient work, model downloads or unregistered orphan files. Callers
  must not interpret this allowance as a physical full-disk guarantee.
  """

  alias Frameshift.Digest
  alias Frameshift.Library.Writer

  @key "storage.objectByteLimit"
  @default 20 * 1024 * 1024 * 1024
  @minimum 1024 * 1024
  @maximum 1024 * 1024 * 1024 * 1024

  @doc "Reads configuration identity and unique registered active/trash usage."
  @spec read(pid()) :: {:ok, map()} | {:error, atom()}
  def read(connection) do
    with {:ok, limit} <- configured_limit(connection) do
      %{rows: [[active, trash, count]]} =
        Exqlite.query!(connection, """
        SELECT COALESCE(SUM(CASE WHEN storage_state = 'active' THEN byte_count ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN storage_state = 'trash' THEN byte_count ELSE 0 END), 0),
               COUNT(*) FROM objects
        """)

      total = active + trash

      {:ok,
       %{
         "objectByteLimit" => limit,
         "revision" => revision(limit),
         "activeBytes" => active,
         "trashBytes" => trash,
         "totalBytes" => total,
         "objectCount" => count,
         "remainingBytes" => max(0, limit - total),
         "overBudget" => total > limit
       }}
    end
  rescue
    _ in Exqlite.Error -> {:error, :storage_unavailable}
  end

  @doc "Updates only an observed configuration revision, preserving retained bytes."
  @spec update(pid(), term(), term()) :: {:ok, map()} | {:error, term()}
  def update(connection, expected, limit) do
    with true <- is_integer(limit) and limit in @minimum..@maximum,
         {:ok, current} <- read(connection),
         true <- expected == current["revision"] do
      connection
      |> Writer.transaction(fn writer ->
        now = System.system_time(:millisecond)

        Exqlite.query!(
          writer,
          """
          INSERT INTO app_settings(key, value, updated_at_ms) VALUES (?, ?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms
          """,
          [@key, Integer.to_string(limit), now]
        )

        Exqlite.query!(
          writer,
          "INSERT INTO audit_entries(operation, detail_json, occurred_at_ms) VALUES (?, ?, ?)",
          ["storage_budget_changed", "{}", now]
        )

        {:ok,
         Map.merge(current, %{
           "objectByteLimit" => limit,
           "revision" => revision(limit),
           "remainingBytes" => max(0, limit - current["totalBytes"]),
           "overBudget" => current["totalBytes"] > limit
         })}
      end)
      |> Writer.unwrap()
    else
      false when not is_integer(limit) or limit < @minimum or limit > @maximum ->
        {:error, :invalid_storage_setting}

      false ->
        {:error, :storage_revision_conflict}

      error ->
        error
    end
  end

  @doc "Refuses new object placement that would exceed the accounted byte allowance."
  @spec admit(pid(), iodata()) :: :ok | {:error, atom()}
  def admit(connection, bytes) do
    binary = IO.iodata_to_binary(bytes)
    digest = Digest.sha256(binary)

    with {:ok, usage} <- read(connection) do
      remaining = usage["remainingBytes"]

      case Exqlite.query!(connection, "SELECT byte_count FROM objects WHERE digest = ?", [digest]) do
        %{rows: [[size]]} when size == byte_size(binary) -> :ok
        %{rows: [[_]]} -> {:error, :content_address_collision}
        %{rows: []} when byte_size(binary) <= remaining -> :ok
        %{rows: []} -> {:error, :library_storage_full}
      end
    end
  rescue
    _ in Exqlite.Error -> {:error, :storage_unavailable}
  end

  defp configured_limit(connection) do
    case Exqlite.query!(connection, "SELECT value FROM app_settings WHERE key = ?", [@key]) do
      %{rows: []} -> {:ok, @default}
      %{rows: [[value]]} -> parse_limit(value)
    end
  end

  defp parse_limit(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in @minimum..@maximum ->
        if Integer.to_string(limit) == value,
          do: {:ok, limit},
          else: {:error, :storage_configuration_invalid}

      _ ->
        {:error, :storage_configuration_invalid}
    end
  end

  defp revision(limit),
    do: %{"objectByteLimit" => limit} |> RFC8785.encode!() |> Digest.sha256()
end
