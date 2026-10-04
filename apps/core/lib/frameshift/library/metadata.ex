defmodule Frameshift.Library.Metadata do
  @moduledoc """
  Projects and edits bounded local artwork metadata under the library writer.

  `read/2` returns title and provenance-bearing labels with a revision digest.
  `update/3` requires that exact revision, replaces user labels and removes only
  explicitly named machine observations. Artwork bytes, source provenance,
  recipes, pins and frame intent are never changed by an edit. SQLite's existing
  ASCII NOCASE label identity is retained; Unicode input is NFC-normalized.

  ## Transactions and recovery

  Only `Frameshift.Library` passes its private connection to this module. Title,
  labels, trigger-maintained FTS and a redacted audit fact share one transaction.
  Missing/removed masters, stale edits and input bounds refuse before mutation.
  A successful edit returns the committed revision for subsequent native drafts.

  `recovery_page/2` exposes 50 digest-ordered removed records and an exclusive
  cursor, with current retention reasons rather than physical display claims.
  It performs no filesystem access or collection. Actual restore and interrupted
  file placement remain owned by the library and `Frameshift.ContentStore`.
  """

  alias Frameshift.Diagnostics.Store
  alias Frameshift.Digest
  alias Frameshift.Library.Writer

  @machine_sources ~w(vision filename metadata)

  @doc "Reads a bounded metadata record and revision, including removed masters."
  @spec read(pid(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(connection, digest) do
    with true <- Digest.valid_sha256?(digest),
         [master] <-
           rows(
             connection,
             "SELECT digest, title, source_kind, width, height, removed_at_ms FROM masters WHERE digest = ?",
             [digest]
           ),
         labels = label_rows(connection, digest),
         true <- length(labels) <= 64 do
      mutable = %{"title" => master["title"], "labels" => labels}

      {:ok,
       Map.merge(mutable, %{
         "itemID" => digest,
         "revision" => Digest.sha256(RFC8785.encode!(mutable)),
         "sourceKind" => master["source_kind"],
         "width" => master["width"],
         "height" => master["height"],
         "removedAtMs" => master["removed_at_ms"]
       })}
    else
      [] -> {:error, :item_not_found}
      false -> {:error, :metadata_unavailable}
    end
  end

  @doc "Commits an exact-revision title/user-label edit and explicit machine dismissals."
  @spec update(pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(connection, digest, command) do
    with true <- Digest.valid_sha256?(command["metadataRevision"]),
         {:ok, current} <- read(connection, digest),
         :ok <- editable(current, command),
         {:ok, title} <- normalize_title(command["title"]),
         {:ok, user_labels} <- normalize_users(command["userLabels"]),
         {:ok, dismissed} <- validate_dismissals(command["dismissedLabels"], current["labels"]),
         :ok <- validate_total(current["labels"], user_labels, dismissed) do
      Writer.transaction(connection, fn writer ->
        Exqlite.query!(writer, "UPDATE masters SET title = ? WHERE digest = ?", [title, digest])

        Exqlite.query!(
          writer,
          "DELETE FROM labels WHERE master_digest = ? AND provenance = 'user'",
          [digest]
        )

        apply_labels(writer, digest, user_labels, dismissed)

        Store.record_audit(writer, "master.metadata-updated", digest, %{
          "commandId" => command["id"]
        })

        read(writer, digest)
      end)
      |> Writer.unwrap()
    else
      false -> {:error, :invalid_metadata}
      error -> error
    end
  end

  @doc "Adds one bounded provenance-bearing observation without changing artwork identity."
  @spec add_label(pid(), String.t(), term(), atom(), term(), term()) :: :ok | {:error, term()}
  def add_label(connection, digest, label, source, confidence, revision) do
    with true <- source in ~w(user vision filename metadata)a,
         {:ok, label} <- normalize_label(label),
         :ok <- validate_observation(confidence, revision),
         {:ok, current} <- read(connection, digest),
         source = Atom.to_string(source),
         :ok <- label_room(current["labels"], label, source) do
      Writer.transaction(connection, fn writer ->
        insert_label(writer, digest, label, source, confidence, revision)
        :ok
      end)
      |> Writer.unwrap()
    else
      false -> {:error, :invalid_label}
      error -> error
    end
  end

  @doc "Reads one page of removed masters with present retention reasons."
  @spec recovery_page(pid(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def recovery_page(connection, after_id) do
    if after_id == nil or Digest.valid_sha256?(after_id) do
      records =
        rows(
          connection,
          """
          SELECT m.digest AS id, m.title, m.removed_at_ms AS removedAtMs,
                 o.storage_state AS storageState,
                 EXISTS(SELECT 1 FROM pins WHERE object_digest = m.digest) AS pinned,
                 EXISTS(SELECT 1 FROM frame_asset_refs WHERE object_digest = m.digest) AS frame,
                 EXISTS(SELECT 1 FROM artifact_recipe_links WHERE master_digest = m.digest) AS artifact,
                 EXISTS(SELECT 1 FROM recipe_sources WHERE source_digest = m.digest) AS recipe
          FROM masters m JOIN objects o ON o.digest = m.digest
          WHERE m.removed_at_ms IS NOT NULL AND m.digest > ?
          ORDER BY m.digest LIMIT 51
          """,
          [after_id || ""]
        )

      page = Enum.take(records, 50)

      {:ok,
       %{
         "items" => Enum.map(page, &recovery_item/1),
         "nextCursor" => if(length(records) > 50, do: List.last(page)["id"])
       }}
    else
      {:error, :invalid_request}
    end
  end

  defp recovery_item(record) do
    reasons = for key <- ~w(pinned frame artifact recipe), record[key] == 1, do: key

    record
    |> Map.take(~w(id title removedAtMs storageState))
    |> Map.put("retentionReasons", reasons)
  end

  defp editable(%{"removedAtMs" => removed}, _) when removed != nil,
    do: {:error, :item_not_found}

  defp editable(current, command) do
    if current["revision"] == command["metadataRevision"],
      do: :ok,
      else: {:error, :metadata_revision_conflict}
  end

  defp normalize_title(value), do: normalize_text(value, 256, :invalid_metadata)
  defp normalize_label(value), do: normalize_text(value, 128, :invalid_label)

  defp normalize_text(value, maximum, error) when is_binary(value) do
    if String.valid?(value) do
      normalized = value |> String.normalize(:nfc) |> String.trim()

      if byte_size(normalized) in 1..maximum and no_controls?(normalized),
        do: {:ok, normalized},
        else: {:error, error}
    else
      {:error, error}
    end
  end

  defp normalize_text(_, _, error), do: {:error, error}

  defp no_controls?(value), do: not String.match?(value, ~r/\p{Cc}/u)

  defp normalize_users(labels) when is_list(labels) and length(labels) <= 32 do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, accepted} ->
      case normalize_label(label) do
        {:ok, value} -> {:cont, {:ok, [value | accepted]}}
        _ -> {:halt, {:error, :invalid_metadata}}
      end
    end)
    |> then(fn
      {:ok, accepted} -> {:ok, accepted |> Enum.reverse() |> Enum.uniq_by(&ascii_key/1)}
      error -> error
    end)
  end

  defp normalize_users(_), do: {:error, :invalid_metadata}

  defp ascii_key(value) do
    for <<byte <- value>>, into: "", do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
  end

  defp validate_dismissals(labels, current) when is_list(labels) and length(labels) <= 64 do
    if Enum.all?(labels, &dismissal?(&1, current)),
      do: {:ok, Enum.uniq(labels)},
      else: {:error, :invalid_metadata}
  end

  defp validate_dismissals(_, _), do: {:error, :invalid_metadata}

  defp dismissal?(%{"label" => label, "provenance" => source} = entry, current) do
    map_size(entry) == 2 and source in @machine_sources and
      Enum.any?(current, &(&1["label"] == label and &1["provenance"] == source))
  end

  defp dismissal?(_, _), do: false

  defp validate_total(labels, users, dismissed) do
    machines = Enum.reject(labels, &(&1["provenance"] == "user"))
    retained = Enum.reject(machines, &(Map.take(&1, ~w(label provenance)) in dismissed))
    if length(retained) + length(users) <= 64, do: :ok, else: {:error, :invalid_metadata}
  end

  defp validate_observation(confidence, revision) do
    cond do
      not valid_confidence?(confidence) -> {:error, :invalid_confidence}
      not valid_revision?(revision) -> {:error, :invalid_label}
      true -> :ok
    end
  end

  defp valid_confidence?(nil), do: true
  defp valid_confidence?(value) when is_number(value), do: value >= 0 and value <= 1
  defp valid_confidence?(_), do: false

  defp valid_revision?(nil), do: true

  defp valid_revision?(value) when is_binary(value),
    do: byte_size(value) <= 128 and String.valid?(value)

  defp valid_revision?(_), do: false

  defp apply_labels(connection, digest, users, dismissed) do
    for label <- dismissed do
      Exqlite.query!(
        connection,
        "DELETE FROM labels WHERE master_digest = ? AND label = ? AND provenance = ?",
        [digest, label["label"], label["provenance"]]
      )
    end

    for label <- users, do: insert_label(connection, digest, label, "user", nil, nil)
  end

  defp label_room(labels, label, source) do
    exists =
      Enum.any?(
        labels,
        &(&1["provenance"] == source and ascii_key(&1["label"]) == ascii_key(label))
      )

    user_count = Enum.count(labels, &(&1["provenance"] == "user"))

    if exists or (length(labels) < 64 and (source != "user" or user_count < 32)),
      do: :ok,
      else: {:error, :label_limit}
  end

  defp insert_label(connection, digest, label, source, confidence, revision) do
    Exqlite.query!(
      connection,
      """
      INSERT INTO labels(master_digest, label, provenance, confidence, revision)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(master_digest, label, provenance)
      DO UPDATE SET confidence = excluded.confidence, revision = excluded.revision
      """,
      [digest, label, source, confidence, revision]
    )
  end

  defp label_rows(connection, digest) do
    rows(
      connection,
      "SELECT label, provenance, confidence, revision FROM labels WHERE master_digest = ? ORDER BY label COLLATE BINARY, provenance LIMIT 65",
      [digest]
    )
  end

  defp rows(connection, sql, params) do
    %{columns: columns, rows: rows} = Exqlite.query!(connection, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
