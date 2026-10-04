defmodule Frameshift.Library.Metadata do
  @moduledoc """
  Projects and edits bounded local artwork metadata under the library writer.

  `read/2` returns title and provenance-bearing labels with a revision digest.
  `update/3` requires that exact revision, replaces user labels and removes only
  explicitly named machine observations. Artwork bytes, source provenance,
  recipes, pins and frame intent are never changed by an edit. SQLite's existing
  ASCII NOCASE label identity is retained; Unicode input is NFC-normalized.

  `record_vision/3` replaces only bounded Vision observations under an observed
  metadata revision, storing one opaque native secure archive and its exact
  input/cohort/digest identity. The core verifies bounds and bytes, while Swift
  owns inference, secure decoding and comparison. These labels cannot qualify
  artwork, rendering or physical compatibility. `analysis/2` and
  `analysis_pending/2` project active records and bounded background work without
  exposing paths or writable handles.

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
  @vision_cohort ~r/\Aapple-vision-v1:c2:f2:macos[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}:(arm64|x86_64):source256-fit\z/

  @doc "Checks the exact supported native adapter identity spelling and byte ceiling."
  @spec vision_cohort?(term()) :: boolean()
  def vision_cohort?(value) when is_binary(value) and byte_size(value) <= 128,
    do: String.valid?(value) and Regex.match?(@vision_cohort, value)

  def vision_cohort?(_), do: false

  @doc "Reads one active master's bounded native archive with byte/digest verification."
  @spec analysis(pid(), String.t()) :: {:ok, map()} | {:error, atom()}
  def analysis(connection, digest) do
    with {:ok, %{"removedAtMs" => nil}} <- read(connection, digest),
         [record] <-
           rows(connection, "SELECT * FROM master_analysis WHERE master_digest = ?", [digest]),
         true <- vision_cohort?(record["cohort"]),
         bytes = record["feature_archive"],
         true <- is_binary(bytes) and byte_size(bytes) in 1..16_384,
         true <- Digest.sha256(bytes) == record["feature_digest"],
         true <-
           Digest.valid_sha256?(record["input_digest"]) and
             Digest.valid_sha256?(record["renderer_build_digest"]) do
      {:ok,
       %{
         "itemID" => digest,
         "cohort" => record["cohort"],
         "inputDigest" => record["input_digest"],
         "rendererBuildDigest" => record["renderer_build_digest"],
         "observedAtMs" => record["observed_at_ms"],
         "featurePrint" => %{
           "cohort" => record["cohort"],
           "archive" => Base.encode64(bytes),
           "digest" => record["feature_digest"]
         }
       }}
    else
      {:ok, _} -> {:error, :item_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :analysis_unavailable}
    end
  rescue
    _ in Exqlite.Error -> {:error, :analysis_unavailable}
  end

  @doc "Lists at most sixteen active masters without a matching native observation cohort."
  @spec analysis_pending(pid(), String.t()) :: {:ok, map()} | {:error, atom()}
  def analysis_pending(connection, cohort) do
    if vision_cohort?(cohort) do
      ids =
        Exqlite.query!(
          connection,
          """
          SELECT m.digest FROM masters m LEFT JOIN master_analysis a ON a.master_digest = m.digest
          WHERE m.removed_at_ms IS NULL AND (a.master_digest IS NULL OR a.cohort != ?)
          ORDER BY m.digest LIMIT 17
          """,
          [cohort]
        ).rows
        |> List.flatten()

      {:ok, %{"itemIDs" => Enum.take(ids, 16), "hasMore" => length(ids) > 16}}
    else
      {:error, :invalid_request}
    end
  rescue
    _ in Exqlite.Error -> {:error, :analysis_unavailable}
  end

  @doc "Atomically replaces Vision rows and one opaque archive without overwriting user work."
  @spec record_vision(pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_vision(connection, digest, command) do
    with true <- vision_cohort?(command["cohort"]),
         true <-
           Digest.valid_sha256?(command["inputDigest"]) and
             Digest.valid_sha256?(command["rendererBuildDigest"]),
         {:ok, current} <- read(connection, digest),
         :ok <- editable(current, command),
         {:ok, labels} <- vision_labels(command["visionLabels"], command["cohort"]),
         true <-
           length(Enum.reject(current["labels"], &(&1["provenance"] == "vision"))) +
             length(labels) <= 64,
         {:ok, archive} <-
           vision_archive(command["featureArchiveChunks"], command["featureDigest"]) do
      Writer.transaction(connection, &persist_vision(&1, digest, command, labels, archive))
      |> Writer.unwrap()
    else
      false -> {:error, :invalid_analysis}
      error -> error
    end
  end

  defp persist_vision(writer, digest, command, labels, archive) do
    Exqlite.query!(
      writer,
      "DELETE FROM labels WHERE master_digest = ? AND provenance = 'vision'",
      [digest]
    )

    for label <- labels,
        do:
          insert_label(
            writer,
            digest,
            label["label"],
            "vision",
            label["confidence"],
            command["cohort"]
          )

    Exqlite.query!(
      writer,
      """
      INSERT INTO master_analysis(master_digest, cohort, input_digest, renderer_build_digest,
                                  feature_digest, feature_archive, observed_at_ms)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(master_digest) DO UPDATE SET cohort = excluded.cohort,
        input_digest = excluded.input_digest, renderer_build_digest = excluded.renderer_build_digest,
        feature_digest = excluded.feature_digest, feature_archive = excluded.feature_archive,
        observed_at_ms = excluded.observed_at_ms
      """,
      [
        digest,
        command["cohort"],
        command["inputDigest"],
        command["rendererBuildDigest"],
        command["featureDigest"],
        {:blob, archive},
        System.system_time(:millisecond)
      ]
    )

    Store.record_audit(writer, "master.vision-recorded", digest, %{
      "commandId" => command["id"]
    })

    read(writer, digest)
  end

  defp vision_archive(chunks, expected) when is_list(chunks) and length(chunks) in 1..3 do
    decoded =
      Enum.map(chunks, fn chunk ->
        if is_binary(chunk) and byte_size(chunk) in 1..8192,
          do: Base.decode64(chunk),
          else: :error
      end)

    if Enum.all?(decoded, &match?({:ok, _}, &1)) do
      bytes = Enum.map(decoded, fn {:ok, bytes} -> bytes end)
      archive = IO.iodata_to_binary(bytes)

      canonical =
        Enum.zip(chunks, bytes)
        |> Enum.all?(fn {text, binary} -> Base.encode64(binary) == text end)

      full = Enum.all?(Enum.drop(bytes, -1), &(byte_size(&1) == 6144))

      if canonical and full and byte_size(archive) in 1..16_384 and
           Digest.sha256(archive) == expected,
         do: {:ok, archive},
         else: {:error, :invalid_analysis}
    else
      {:error, :invalid_analysis}
    end
  end

  defp vision_archive(_, _), do: {:error, :invalid_analysis}

  defp vision_labels(labels, cohort) when is_list(labels) and length(labels) <= 32 do
    Enum.reduce_while(labels, {:ok, [], MapSet.new()}, fn label, {:ok, accepted, seen} ->
      with %{
             "label" => text,
             "provenance" => "vision",
             "confidence" => confidence,
             "revision" => ^cohort
           } <- label,
           true <-
             Enum.sort(Map.keys(label)) == Enum.sort(~w(label provenance confidence revision)),
           true <- is_number(confidence) and confidence >= 0.5 and confidence <= 1,
           {:ok, normalized} <- normalize_label(text),
           key = ascii_key(normalized),
           false <- MapSet.member?(seen, key) do
        {:cont, {:ok, [Map.put(label, "label", normalized) | accepted], MapSet.put(seen, key)}}
      else
        _ -> {:halt, {:error, :invalid_analysis}}
      end
    end)
    |> case do
      {:ok, accepted, _} -> {:ok, Enum.reverse(accepted)}
      error -> error
    end
  end

  defp vision_labels(_, _), do: {:error, :invalid_analysis}

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
