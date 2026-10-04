defmodule Frameshift.Playlist.Store do
  @moduledoc """
  Persists complete pending and active still playlists under the library writer.

  `queue/6` validates paired-frame/profile capability, exact playlist/entry bytes,
  capacity and command intent before atomically retaining the replacement manifest
  and every required artifact. The prior active cycle stays protected while a
  replacement is pending; a timeout cannot erase known-good references.

  ## Serving and confirmation

  `pending_body/3` and `pending_asset?/3` expose only the caller frame's current
  outbox revision. `confirm/3` activates the exact acknowledged replacement;
  a stale/mismatched acknowledgement cannot install another revision.
  `cancel_pending/2` and `suspend/2` handle supersession by a single-image send
  without inventing receiver completion.

  `status/2` and `members/2` provide bounded local presentation of loop state.
  All writes use the connection owned by `Frameshift.Library`, including audit
  and qualified-work custody. Library pinning, queued intent, installed playlist
  and the physically displayed still retain distinct meanings.
  """

  alias Frameshift.Diagnostics.Store, as: DiagnosticsStore
  alias Frameshift.Digest
  alias Frameshift.Library.Writer
  alias Frameshift.Protocol.Schema
  alias Frameshift.Qualification.WorkStore

  @maximum_playlist_bytes 65_536

  @doc "Validates and queues a complete pull playlist in one durable transaction."
  @spec queue(pid(), map(), String.t(), map(), [map()], String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def queue(connection, frame, profile_id, playlist, entries, command_id) do
    with :ok <- validate_frame(frame, profile_id),
         :ok <- validate_plan(frame, playlist, entries),
         :ok <- validate_intent(connection, frame["frame_id"], playlist["revision"], command_id),
         {:ok, prepared} <- validate_entries(connection, frame, profile_id, playlist, entries),
         :ok <- validate_capacity(connection, frame, prepared) do
      persist_queue(connection, frame, profile_id, playlist, prepared, command_id)
    end
  end

  @doc "Reads the exact pending playlist body only for the caller's current outbox."
  @spec pending_body(pid(), String.t(), String.t()) :: {:ok, binary()} | :not_found
  def pending_body(connection, frame_id, revision) do
    case Exqlite.query!(
           connection,
           """
           SELECT p.canonical_json FROM frame_playlists p
           JOIN frame_outboxes o ON o.frame_id = p.frame_id
           WHERE p.frame_id = ? AND p.revision = ? AND p.status = 'pending'
             AND o.playlist_revision = p.revision
           """,
           [frame_id, revision]
         ).rows do
      [[body]] -> {:ok, body}
      [] -> :not_found
    end
  end

  @doc "Checks whether the current outbox authorizes one playlist artifact."
  @spec pending_asset?(pid(), String.t(), String.t()) :: boolean()
  def pending_asset?(connection, frame_id, digest) do
    Exqlite.query!(
      connection,
      """
      SELECT 1 FROM frame_outboxes o
      JOIN frame_playlists p ON p.frame_id = o.frame_id
        AND p.revision = o.playlist_revision AND p.status = 'pending'
      JOIN frame_playlist_entries e ON e.frame_id = p.frame_id AND e.revision = p.revision
      WHERE o.frame_id = ? AND e.artifact_digest = ? LIMIT 1
      """,
      [frame_id, digest]
    ).rows != []
  end

  @doc "Reads the visible loop state without exposing its full artifact list to the shell."
  @spec status(pid(), String.t()) :: map() | nil
  def status(connection, frame_id) do
    case Exqlite.query!(
           connection,
           """
           SELECT p.status, p.revision, p.canonical_json, COUNT(e.ordinal),
             EXISTS (
               SELECT 1 FROM frame_playlists active
               WHERE active.frame_id = p.frame_id AND active.status = 'active'
             )
           FROM frame_playlists p
           JOIN frame_playlist_entries e ON e.frame_id = p.frame_id AND e.revision = p.revision
           WHERE p.frame_id = ?
           GROUP BY p.frame_id, p.revision
           ORDER BY CASE p.status WHEN 'pending' THEN 0 WHEN 'active' THEN 1 ELSE 2 END
           LIMIT 1
           """,
           [frame_id]
         ).rows do
      [[state, revision, body, count, has_active]] ->
        {:ok, playlist} = RFC8785.decode(body)

        %{
          "status" => state,
          "revision" => revision,
          "entryCount" => count,
          "dwellMs" => playlist["entries"] |> hd() |> Map.fetch!("dwellMs"),
          "replacingActive" => state == "pending" and has_active == 1
        }

      [] ->
        nil
    end
  end

  @doc "Returns the chosen pending or active loop's source masters for local presentation."
  @spec members(pid(), String.t()) :: map() | nil
  def members(connection, frame_id) do
    case status(connection, frame_id) do
      nil ->
        nil

      %{"status" => state, "revision" => revision} ->
        masters =
          Exqlite.query!(
            connection,
            """
            SELECT master_digest FROM frame_playlist_entries
            WHERE frame_id = ? AND revision = ? ORDER BY ordinal
            """,
            [frame_id, revision]
          ).rows
          |> Enum.map(&hd/1)

        %{"status" => state, "masterDigests" => masters}
    end
  end

  @doc "Activates a confirmed pending revision while retaining only its protected assets."
  @spec confirm(pid(), String.t(), String.t() | nil) :: :ok | {:error, :playlist_missing}
  def confirm(_, _, nil), do: :ok

  def confirm(connection, frame_id, revision) do
    case pending_body(connection, frame_id, revision) do
      {:ok, _} ->
        Exqlite.query!(
          connection,
          "DELETE FROM frame_playlists WHERE frame_id = ? AND status IN ('active', 'suspended')",
          [frame_id]
        )

        Exqlite.query!(
          connection,
          """
          UPDATE frame_playlists SET status = 'active', confirmed_at_ms = ?
          WHERE frame_id = ? AND revision = ? AND status = 'pending'
          """,
          [System.os_time(:millisecond), frame_id, revision]
        )

        rebuild_refs(connection, frame_id)
        :ok

      :not_found ->
        {:error, :playlist_missing}
    end
  end

  @doc "Drops an unconfirmed replacement superseded by a single-image send."
  @spec cancel_pending(pid(), String.t()) :: :ok
  def cancel_pending(connection, frame_id) do
    Exqlite.query!(
      connection,
      "DELETE FROM frame_playlists WHERE frame_id = ? AND status = 'pending'",
      [frame_id]
    )

    rebuild_refs(connection, frame_id)
    :ok
  end

  @doc "Marks the old cycle suspended after a single-image acknowledgement."
  @spec suspend(pid(), String.t()) :: :ok
  def suspend(connection, frame_id) do
    Exqlite.query!(
      connection,
      """
      DELETE FROM frame_playlists
      WHERE frame_id = ? AND status = 'suspended'
        AND EXISTS (
          SELECT 1 FROM frame_playlists
          WHERE frame_id = ? AND status = 'active'
        )
      """,
      [frame_id, frame_id]
    )

    Exqlite.query!(
      connection,
      "UPDATE frame_playlists SET status = 'suspended' WHERE frame_id = ? AND status = 'active'",
      [frame_id]
    )

    rebuild_refs(connection, frame_id)
    :ok
  end

  defp validate_frame(%{"capabilities" => %{"transferModes" => modes} = capabilities}, profile_id) do
    profiles = capabilities["storage"]["artifactProfiles"]

    cond do
      "pull" not in modes -> {:error, :pull_not_supported}
      not Enum.any?(profiles, &(&1["id"] == profile_id)) -> {:error, :unsupported_profile}
      true -> :ok
    end
  end

  defp validate_frame(_, _), do: {:error, :frame_not_paired}

  defp validate_intent(connection, frame_id, revision, command_id) do
    existing =
      Exqlite.query!(
        connection,
        "SELECT status FROM frame_playlists WHERE frame_id = ? AND revision = ?",
        [frame_id, revision]
      ).rows

    cond do
      command_id != nil and (not is_binary(command_id) or byte_size(command_id) not in 1..64) ->
        {:error, :invalid_command}

      existing == [["active"]] ->
        {:error, :already_active}

      existing == [["pending"]] ->
        {:error, :playlist_pending}

      true ->
        :ok
    end
  end

  defp validate_plan(frame, playlist, entries) when is_map(playlist) and is_list(entries) do
    storage = frame["capabilities"]["storage"]
    minimum = frame["capabilities"]["refresh"]["minimumDwellMs"]
    payload = Map.take(playlist, ["mode", "entries"])

    with true <- string_keys?(playlist),
         :ok <- Schema.validate("playlist", playlist) do
      cond do
        byte_size(RFC8785.encode!(playlist)) > @maximum_playlist_bytes ->
          {:error, :playlist_too_large}

        playlist["revision"] != Digest.sha256(RFC8785.encode!(payload)) ->
          {:error, :playlist_revision_mismatch}

        length(playlist["entries"]) > storage["maximumPlaylistLength"] ->
          {:error, :playlist_too_long}

        length(playlist["entries"]) > storage["maximumAssetCount"] ->
          {:error, :storage_full}

        length(playlist["entries"]) != length(entries) ->
          {:error, :playlist_entry_mismatch}

        Enum.any?(playlist["entries"], &(&1["dwellMs"] < minimum)) ->
          {:error, :dwell_too_short}

        true ->
          :ok
      end
    else
      false -> {:error, :invalid_playlist}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_plan(_, _, _), do: {:error, :invalid_playlist}

  defp string_keys?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and string_keys?(value) end)
  end

  defp string_keys?(list) when is_list(list), do: Enum.all?(list, &string_keys?/1)
  defp string_keys?(_), do: true

  defp validate_entries(connection, frame, profile_id, playlist, entries) do
    playlist["entries"]
    |> Enum.zip(entries)
    |> Enum.reduce_while({:ok, []}, fn {scheduled, entry}, {:ok, prepared} ->
      case validate_entry(connection, frame, profile_id, scheduled, entry) do
        {:ok, record} -> {:cont, {:ok, [record | prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end)
  end

  defp validate_entry(connection, frame, profile_id, scheduled, entry) when is_map(entry) do
    digest = entry["artifactDigest"]
    master = entry["masterDigest"]
    work = entry["workDigest"]

    with true <- digest == scheduled["assetDigest"] and Digest.valid_sha256?(master),
         [[byte_count]] <-
           Exqlite.query!(
             connection,
             """
             SELECT o.byte_count FROM artifact_recipe_links l
             JOIN objects o ON o.digest = l.artifact_digest
             WHERE l.artifact_digest = ? AND l.master_digest = ? AND l.profile_id = ?
               AND o.storage_state = 'active' LIMIT 1
             """,
             [digest, master, profile_id]
           ).rows,
         {:ok, qualification} <-
           WorkStore.delivery_binding(
             connection,
             work,
             frame["frame_id"],
             digest,
             profile_id,
             "pull"
           ) do
      {:ok,
       %{
         master: master,
         digest: digest,
         bytes: byte_count,
         work: work,
         qualification: qualification
       }}
    else
      false -> {:error, :playlist_entry_mismatch}
      [] -> {:error, :artifact_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_entry(_, _, _, _, _), do: {:error, :playlist_entry_mismatch}

  defp validate_capacity(connection, frame, prepared) do
    frame_id = frame["frame_id"]
    storage = frame["capabilities"]["storage"]

    displayed =
      Exqlite.query!(
        connection,
        """
        SELECT object_digest FROM frame_asset_refs
        WHERE frame_id = ? AND role IN ('current', 'previous-known-good')
        """,
        [frame_id]
      ).rows
      |> Enum.map(&hd/1)

    retained =
      Exqlite.query!(
        connection,
        """
        SELECT e.artifact_digest FROM frame_playlists p
        JOIN frame_playlist_entries e ON e.frame_id = p.frame_id AND e.revision = p.revision
        WHERE p.frame_id = ? AND p.status IN ('active', 'suspended')
        """,
        [frame_id]
      ).rows
      |> Enum.map(&hd/1)

    digests = Enum.uniq(displayed ++ retained ++ Enum.map(prepared, & &1.digest))

    byte_count =
      Enum.sum_by(digests, fn digest ->
        [[bytes]] =
          Exqlite.query!(connection, "SELECT byte_count FROM objects WHERE digest = ?", [digest]).rows

        bytes
      end)

    if length(digests) <= storage["maximumAssetCount"] and byte_count <= storage["totalBytes"],
      do: :ok,
      else: {:error, :storage_full}
  end

  defp persist_queue(connection, frame, profile_id, playlist, prepared, command_id) do
    frame_id = frame["frame_id"]
    revision = playlist["revision"]
    body = RFC8785.encode!(playlist)

    case Writer.transaction(connection, fn owner ->
           replace_pending(owner, frame_id, revision, profile_id, body, command_id, prepared)

           manifest =
             queue_manifest(owner, frame_id, revision, profile_id, hd(prepared), command_id)

           rebuild_refs(owner, frame_id)

           DiagnosticsStore.record_audit(owner, "playlist.queued", revision, %{
             "frameId" => frame_id,
             "commandId" => command_id,
             "entryCount" => length(prepared)
           })

           manifest
         end) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_pending(connection, frame_id, revision, profile_id, body, command_id, entries) do
    Exqlite.query!(
      connection,
      "DELETE FROM frame_playlists WHERE frame_id = ? AND status = 'pending'",
      [frame_id]
    )

    Exqlite.query!(
      connection,
      "DELETE FROM frame_playlists WHERE frame_id = ? AND status = 'suspended' AND revision = ?",
      [frame_id, revision]
    )

    Exqlite.query!(
      connection,
      """
      INSERT INTO frame_playlists(
        frame_id, revision, status, profile_id, canonical_json, command_id, created_at_ms
      ) VALUES (?, ?, 'pending', ?, ?, ?, ?)
      """,
      [frame_id, revision, profile_id, body, command_id, System.os_time(:millisecond)]
    )

    Enum.with_index(entries, fn entry, ordinal ->
      Exqlite.query!(
        connection,
        """
        INSERT INTO frame_playlist_entries(
          frame_id, revision, ordinal, master_digest, artifact_digest,
          work_digest, qualification_digest
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          frame_id,
          revision,
          ordinal,
          entry.master,
          entry.digest,
          entry.work,
          entry.qualification
        ]
      )
    end)
  end

  defp queue_manifest(connection, frame_id, revision, profile_id, first, command_id) do
    outbox_revision =
      Exqlite.query!(
        connection,
        """
        INSERT INTO frame_outbox_revisions(frame_id, revision) VALUES (?, 1)
        ON CONFLICT(frame_id) DO UPDATE SET revision = revision + 1
        RETURNING revision
        """,
        [frame_id]
      ).rows
      |> hd()
      |> hd()

    Exqlite.query!(
      connection,
      "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = 'queued'",
      [frame_id]
    )

    Exqlite.query!(
      connection,
      """
      INSERT INTO frame_outboxes(
        frame_id, revision, desired_digest, profile_id, playlist_revision, queued_at_ms,
        command_id, work_digest, qualification_digest
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(frame_id) DO UPDATE SET
        revision = excluded.revision, desired_digest = excluded.desired_digest,
        profile_id = excluded.profile_id, playlist_revision = excluded.playlist_revision,
        queued_at_ms = excluded.queued_at_ms, command_id = excluded.command_id,
        work_digest = excluded.work_digest,
        qualification_digest = excluded.qualification_digest
      """,
      [
        frame_id,
        outbox_revision,
        first.digest,
        profile_id,
        revision,
        System.os_time(:millisecond),
        command_id,
        first.work,
        first.qualification
      ]
    )

    Exqlite.query!(
      connection,
      """
      INSERT INTO frame_asset_refs(
        frame_id, role, object_digest, work_digest, qualification_digest
      ) VALUES (?, 'queued', ?, ?, ?)
      """,
      [frame_id, first.digest, first.work, first.qualification]
    )

    %{
      "revision" => outbox_revision,
      "desiredAsset" => first.digest,
      "artifactProfile" => profile_id,
      "playlistRevision" => revision
    }
  end

  defp rebuild_refs(connection, frame_id) do
    Exqlite.query!(
      connection,
      "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = 'playlist'",
      [frame_id]
    )

    Exqlite.query!(
      connection,
      """
      INSERT INTO frame_asset_refs(frame_id, role, object_digest)
      SELECT DISTINCT p.frame_id, 'playlist', e.artifact_digest
      FROM frame_playlists p
      JOIN frame_playlist_entries e ON e.frame_id = p.frame_id AND e.revision = p.revision
      WHERE p.frame_id = ?
      """,
      [frame_id]
    )
  end
end
