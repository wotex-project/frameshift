defmodule Frameshift.Library.Migrations do
  @moduledoc false

  @search_backfill """
  INSERT INTO master_search(rowid, title, labels)
  SELECT m.rowid, m.title,
         COALESCE((SELECT group_concat(label, ' ') FROM labels WHERE master_digest = m.digest), '')
  FROM masters m WHERE m.removed_at_ms IS NULL
  """

  @migrations [
    {1,
     [
       """
       CREATE TABLE objects (
         digest TEXT PRIMARY KEY CHECK (
           length(digest) = 71 AND
           substr(digest, 1, 7) = 'sha256:' AND
           substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
         media_type TEXT NOT NULL,
         storage_state TEXT NOT NULL DEFAULT 'active' CHECK (storage_state IN ('active', 'trash')),
         created_at_ms INTEGER NOT NULL,
         trashed_at_ms INTEGER
       ) STRICT
       """,
       """
       CREATE TABLE masters (
         digest TEXT PRIMARY KEY REFERENCES objects(digest) ON DELETE CASCADE,
         title TEXT NOT NULL,
         source_kind TEXT NOT NULL CHECK (source_kind IN ('import', 'generated')),
         width INTEGER NOT NULL CHECK (width > 0),
         height INTEGER NOT NULL CHECK (height > 0),
         color_profile TEXT,
         orientation INTEGER NOT NULL DEFAULT 1 CHECK (orientation BETWEEN 1 AND 8),
         provenance_json TEXT NOT NULL,
         parent_digest TEXT REFERENCES masters(digest) ON DELETE RESTRICT,
         generation_recipe_hash TEXT,
         removed_at_ms INTEGER
       ) STRICT
       """,
       """
       CREATE TABLE recipes (
         hash TEXT PRIMARY KEY CHECK (
           length(hash) = 71 AND
           substr(hash, 1, 7) = 'sha256:' AND
           substr(hash, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         kind TEXT NOT NULL CHECK (kind IN ('generation', 'composition')),
         canonical_json TEXT NOT NULL,
         created_at_ms INTEGER NOT NULL
       ) STRICT
       """,
       """
       CREATE TABLE recipe_sources (
         recipe_hash TEXT NOT NULL REFERENCES recipes(hash) ON DELETE CASCADE,
         source_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE RESTRICT,
         ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
         PRIMARY KEY (recipe_hash, ordinal),
         UNIQUE (recipe_hash, source_digest, ordinal)
       ) STRICT
       """,
       """
       CREATE TABLE artifacts (
         digest TEXT PRIMARY KEY REFERENCES objects(digest) ON DELETE CASCADE,
         master_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE RESTRICT,
         recipe_hash TEXT NOT NULL REFERENCES recipes(hash) ON DELETE RESTRICT,
         profile_id TEXT NOT NULL,
         renderer_revision TEXT NOT NULL,
         UNIQUE (master_digest, recipe_hash, profile_id, renderer_revision)
       ) STRICT
       """,
       """
       CREATE TABLE labels (
         master_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE CASCADE,
         label TEXT NOT NULL COLLATE NOCASE,
         provenance TEXT NOT NULL CHECK (provenance IN ('user', 'vision', 'filename', 'metadata')),
         confidence REAL,
         revision TEXT,
         PRIMARY KEY (master_digest, label, provenance)
       ) STRICT
       """,
       """
       CREATE TABLE pins (
         object_digest TEXT PRIMARY KEY REFERENCES objects(digest) ON DELETE CASCADE,
         pinned_at_ms INTEGER NOT NULL
       ) STRICT
       """,
       """
       CREATE TABLE frame_asset_refs (
         frame_id TEXT NOT NULL,
         role TEXT NOT NULL CHECK (role IN ('desired', 'current', 'previous-known-good', 'queued', 'playlist')),
         object_digest TEXT NOT NULL REFERENCES objects(digest) ON DELETE RESTRICT,
         work_digest TEXT REFERENCES qualified_work(digest) ON DELETE RESTRICT,
         qualification_digest TEXT REFERENCES qualified_bindings(digest) ON DELETE RESTRICT,
         PRIMARY KEY (frame_id, role, object_digest)
       ) STRICT
       """,
       """
       CREATE TRIGGER frame_asset_custody_insert BEFORE INSERT ON frame_asset_refs
       WHEN (NEW.work_digest IS NULL) != (NEW.qualification_digest IS NULL)
       BEGIN SELECT RAISE(ABORT, 'incomplete frame asset qualification custody'); END
       """,
       """
       CREATE TRIGGER frame_asset_custody_update BEFORE UPDATE ON frame_asset_refs
       WHEN (NEW.work_digest IS NULL) != (NEW.qualification_digest IS NULL)
       BEGIN SELECT RAISE(ABORT, 'incomplete frame asset qualification custody'); END
       """,
       """
       CREATE TABLE audit_entries (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         operation TEXT NOT NULL,
         subject_digest TEXT,
         detail_json TEXT NOT NULL,
         occurred_at_ms INTEGER NOT NULL,
         correlation_id TEXT,
         attempt_id TEXT
       ) STRICT
       """,
       "CREATE INDEX masters_active_title ON masters(removed_at_ms, title)",
       "CREATE INDEX labels_lookup ON labels(label, master_digest)",
       "CREATE INDEX frame_asset_refs_digest ON frame_asset_refs(object_digest)",
       "CREATE INDEX audit_entries_recent ON audit_entries(id DESC)",
       "CREATE INDEX audit_entries_correlation ON audit_entries(correlation_id, id DESC)"
     ]},
    {2,
     [
       """
       CREATE TABLE frame_outbox_revisions (
         frame_id TEXT PRIMARY KEY,
         revision INTEGER NOT NULL CHECK (revision > 0)
       ) STRICT
       """,
       """
       CREATE TABLE frame_outboxes (
         frame_id TEXT PRIMARY KEY REFERENCES frame_outbox_revisions(frame_id) ON DELETE RESTRICT,
         revision INTEGER NOT NULL CHECK (revision > 0),
         desired_digest TEXT NOT NULL REFERENCES objects(digest) ON DELETE RESTRICT,
         profile_id TEXT NOT NULL,
         playlist_revision TEXT,
         queued_at_ms INTEGER NOT NULL,
         command_id TEXT,
         work_digest TEXT REFERENCES qualified_work(digest) ON DELETE RESTRICT,
         qualification_digest TEXT REFERENCES qualified_bindings(digest) ON DELETE RESTRICT
       ) STRICT
       """,
       """
       CREATE TRIGGER frame_outbox_custody_insert BEFORE INSERT ON frame_outboxes
       WHEN (NEW.work_digest IS NULL) != (NEW.qualification_digest IS NULL)
       BEGIN SELECT RAISE(ABORT, 'incomplete outbox qualification custody'); END
       """,
       """
       CREATE TRIGGER frame_outbox_custody_update BEFORE UPDATE ON frame_outboxes
       WHEN (NEW.work_digest IS NULL) != (NEW.qualification_digest IS NULL)
       BEGIN SELECT RAISE(ABORT, 'incomplete outbox qualification custody'); END
       """
     ]},
    {3,
     [
       """
       CREATE TABLE generation_results (
         recipe_hash TEXT PRIMARY KEY REFERENCES recipes(hash) ON DELETE RESTRICT,
         master_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE RESTRICT,
         provider_result_id TEXT,
         provenance_json TEXT NOT NULL,
         created_at_ms INTEGER NOT NULL
       ) STRICT
       """,
       """
       INSERT INTO generation_results(
         recipe_hash, master_digest, provider_result_id, provenance_json, created_at_ms
       )
       SELECT m.generation_recipe_hash, m.digest, NULL, m.provenance_json, o.created_at_ms
       FROM masters m
       JOIN objects o ON o.digest = m.digest
       WHERE m.generation_recipe_hash IS NOT NULL
       ON CONFLICT(recipe_hash) DO NOTHING
       """,
       "CREATE INDEX generation_results_master ON generation_results(master_digest)"
     ]},
    {4,
     [
       """
       CREATE TABLE app_settings (
         key TEXT PRIMARY KEY,
         value TEXT NOT NULL,
         updated_at_ms INTEGER NOT NULL
       ) STRICT
       """
     ]},
    {5,
     [
       """
       CREATE TABLE paired_frames (
         frame_id TEXT PRIMARY KEY,
         thing_id TEXT NOT NULL UNIQUE,
         title TEXT NOT NULL,
         medium TEXT NOT NULL CHECK (medium IN ('paper', 'photo', 'pixel')),
         td_json TEXT NOT NULL,
         capabilities_json TEXT NOT NULL,
         credential_ref TEXT NOT NULL,
         server_spki_fingerprint TEXT NOT NULL CHECK (
           length(server_spki_fingerprint) = 71 AND
           substr(server_spki_fingerprint, 1, 7) = 'sha256:' AND
           substr(server_spki_fingerprint, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         connection_state TEXT NOT NULL DEFAULT 'waitingForContact' CHECK (
           connection_state IN ('waitingForContact', 'displayed', 'failed')
         ),
         paired_at_ms INTEGER NOT NULL,
         updated_at_ms INTEGER NOT NULL
       ) STRICT
       """,
       "CREATE INDEX paired_frames_title ON paired_frames(title COLLATE NOCASE, frame_id)",
       "CREATE UNIQUE INDEX paired_frames_server_spki_unique ON paired_frames(server_spki_fingerprint)"
     ]},
    {6,
     [
       """
       CREATE TABLE command_receipts (
         command_id TEXT PRIMARY KEY CHECK (length(command_id) BETWEEN 1 AND 64),
         command_hash TEXT NOT NULL CHECK (
           length(command_hash) = 71 AND
           substr(command_hash, 1, 7) = 'sha256:' AND
           substr(command_hash, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         status TEXT NOT NULL CHECK (status IN ('pending', 'succeeded', 'failed')),
         error_code TEXT CHECK (
           error_code IS NULL OR (
             length(error_code) BETWEEN 1 AND 64 AND
             error_code NOT GLOB '*[^a-z0-9_]*'
           )
         ),
         created_at_ms INTEGER NOT NULL,
         completed_at_ms INTEGER,
         CHECK (
           (status = 'pending' AND error_code IS NULL AND completed_at_ms IS NULL) OR
           (status = 'succeeded' AND error_code IS NULL AND completed_at_ms IS NOT NULL) OR
           (status = 'failed' AND error_code IS NOT NULL AND completed_at_ms IS NOT NULL)
         )
       ) STRICT
       """,
       "CREATE INDEX command_receipts_completed ON command_receipts(completed_at_ms DESC)"
     ]},
    {7,
     [
       """
       CREATE TABLE frame_direct_deliveries (
         frame_id TEXT PRIMARY KEY REFERENCES paired_frames(frame_id) ON DELETE CASCADE,
         revision INTEGER NOT NULL CHECK (revision > 0),
         desired_digest TEXT NOT NULL REFERENCES artifacts(digest) ON DELETE RESTRICT,
         profile_id TEXT NOT NULL,
         request_id TEXT NOT NULL CHECK (length(request_id) BETWEEN 1 AND 64),
         status TEXT NOT NULL CHECK (status IN ('pending', 'displayed')),
         updated_at_ms INTEGER NOT NULL,
         work_digest TEXT REFERENCES qualified_work(digest) ON DELETE RESTRICT,
         qualification_digest TEXT REFERENCES qualified_bindings(digest) ON DELETE RESTRICT
       ) STRICT
       """,
       """
       CREATE TRIGGER frame_direct_custody_insert BEFORE INSERT ON frame_direct_deliveries
       WHEN (NEW.work_digest IS NULL) != (NEW.qualification_digest IS NULL)
       BEGIN SELECT RAISE(ABORT, 'incomplete direct qualification custody'); END
       """,
       """
       CREATE TRIGGER frame_direct_custody_update BEFORE UPDATE ON frame_direct_deliveries
       WHEN (NEW.work_digest IS NULL) != (NEW.qualification_digest IS NULL)
       BEGIN SELECT RAISE(ABORT, 'incomplete direct qualification custody'); END
       """
     ]},
    {8,
     [
       """
       CREATE TABLE metric_rollups (
         metric TEXT NOT NULL CHECK (length(metric) BETWEEN 1 AND 96),
         bucket_ms INTEGER NOT NULL,
         granularity TEXT NOT NULL CHECK (granularity IN ('minute', 'hour')),
         dimensions_json TEXT NOT NULL CHECK (length(dimensions_json) <= 256),
         sample_count INTEGER NOT NULL CHECK (sample_count >= 0),
         value_sum REAL NOT NULL,
         value_min REAL NOT NULL,
         value_max REAL NOT NULL,
         histogram_json TEXT NOT NULL CHECK (length(histogram_json) <= 512),
         PRIMARY KEY(metric, bucket_ms, granularity, dimensions_json)
       ) STRICT
       """,
       "CREATE INDEX metric_rollups_recent ON metric_rollups(bucket_ms DESC, granularity)"
     ]},
    {10,
     [
       """
       CREATE TABLE qualified_bindings (
         digest TEXT PRIMARY KEY CHECK (
           length(digest) = 71 AND
           substr(digest, 1, 7) = 'sha256:' AND
           substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         frame_id TEXT NOT NULL,
         profile_id TEXT NOT NULL,
         manifest_json TEXT NOT NULL,
         status TEXT NOT NULL CHECK (status IN ('candidate', 'admitted', 'retired')),
         evidence_json TEXT,
         created_at_ms INTEGER NOT NULL,
         admitted_at_ms INTEGER
       ) STRICT
       """,
       "CREATE INDEX qualified_bindings_frame ON qualified_bindings(frame_id, status)",
       """
       CREATE TABLE active_qualifications (
         frame_id TEXT PRIMARY KEY REFERENCES paired_frames(frame_id) ON DELETE CASCADE,
         binding_digest TEXT NOT NULL REFERENCES qualified_bindings(digest) ON DELETE RESTRICT,
         activated_at_ms INTEGER NOT NULL
       ) STRICT
       """
     ]},
    {11,
     [
       """
       CREATE TABLE qualified_work (
         digest TEXT PRIMARY KEY CHECK (
           length(digest) = 71 AND substr(digest, 1, 7) = 'sha256:' AND
           substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         binding_digest TEXT NOT NULL REFERENCES qualified_bindings(digest) ON DELETE RESTRICT,
         frame_id TEXT NOT NULL,
         master_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE RESTRICT,
         recipe_digest TEXT NOT NULL REFERENCES recipes(hash) ON DELETE RESTRICT,
         manifest_json TEXT NOT NULL,
         accepted_at_ms INTEGER NOT NULL
       ) STRICT
       """,
       "CREATE INDEX qualified_work_binding ON qualified_work(binding_digest, accepted_at_ms)",
       """
       CREATE TABLE qualified_results (
         digest TEXT PRIMARY KEY CHECK (
           length(digest) = 71 AND substr(digest, 1, 7) = 'sha256:' AND
           substr(digest, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         work_digest TEXT NOT NULL UNIQUE REFERENCES qualified_work(digest) ON DELETE RESTRICT,
         artifact_digest TEXT NOT NULL REFERENCES artifacts(digest) ON DELETE RESTRICT,
         manifest_json TEXT NOT NULL,
         created_at_ms INTEGER NOT NULL
       ) STRICT
       """
     ]},
    {13,
     [
       """
       CREATE TABLE artifact_recipe_links (
         recipe_hash TEXT NOT NULL REFERENCES recipes(hash) ON DELETE RESTRICT,
         profile_id TEXT NOT NULL,
         renderer_revision TEXT NOT NULL,
         master_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE RESTRICT,
         artifact_digest TEXT NOT NULL REFERENCES artifacts(digest) ON DELETE RESTRICT,
         PRIMARY KEY (recipe_hash, profile_id, renderer_revision)
       ) STRICT
       """,
       """
       INSERT INTO artifact_recipe_links(
         recipe_hash, profile_id, renderer_revision, master_digest, artifact_digest
       )
       SELECT recipe_hash, profile_id, renderer_revision, master_digest, digest
       FROM artifacts
       """,
       "CREATE INDEX artifact_recipe_links_digest ON artifact_recipe_links(artifact_digest)"
     ]},
    {14,
     [
       """
       CREATE TABLE frame_playlists (
         frame_id TEXT NOT NULL REFERENCES paired_frames(frame_id) ON DELETE CASCADE,
         revision TEXT NOT NULL CHECK (
           length(revision) = 71 AND substr(revision, 1, 7) = 'sha256:' AND
           substr(revision, 8) NOT GLOB '*[^0-9a-f]*'
         ),
         status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'suspended')),
         profile_id TEXT NOT NULL,
         capability_digest TEXT NOT NULL,
         canonical_json TEXT NOT NULL,
         command_id TEXT,
         created_at_ms INTEGER NOT NULL,
         confirmed_at_ms INTEGER,
         PRIMARY KEY (frame_id, revision),
         UNIQUE (frame_id, status)
       ) STRICT
       """,
       """
       CREATE TABLE frame_playlist_entries (
         frame_id TEXT NOT NULL,
         revision TEXT NOT NULL,
         ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
         master_digest TEXT NOT NULL REFERENCES masters(digest) ON DELETE RESTRICT,
         artifact_digest TEXT NOT NULL REFERENCES artifacts(digest) ON DELETE RESTRICT,
         work_digest TEXT REFERENCES qualified_work(digest) ON DELETE RESTRICT,
         qualification_digest TEXT REFERENCES qualified_bindings(digest) ON DELETE RESTRICT,
         PRIMARY KEY (frame_id, revision, ordinal),
         FOREIGN KEY (frame_id, revision) REFERENCES frame_playlists(frame_id, revision)
           ON DELETE CASCADE
       ) STRICT
       """,
       "CREATE INDEX frame_playlist_entries_asset ON frame_playlist_entries(artifact_digest)"
     ]},
    {15,
     [
       "CREATE VIRTUAL TABLE master_search USING fts5(title, labels, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')",
       @search_backfill,
       """
       CREATE TRIGGER master_search_insert AFTER INSERT ON masters
       WHEN NEW.removed_at_ms IS NULL
       BEGIN
         INSERT INTO master_search(rowid, title, labels)
         VALUES (NEW.rowid, NEW.title, '');
       END
       """,
       """
       CREATE TRIGGER master_search_update AFTER UPDATE OF title, removed_at_ms ON masters
       BEGIN
         DELETE FROM master_search WHERE rowid = OLD.rowid;
         INSERT INTO master_search(rowid, title, labels)
         SELECT NEW.rowid, NEW.title,
                COALESCE((SELECT group_concat(label, ' ') FROM labels
                          WHERE master_digest = NEW.digest), '')
         WHERE NEW.removed_at_ms IS NULL;
       END
       """,
       """
       CREATE TRIGGER master_search_delete AFTER DELETE ON masters
       BEGIN
         DELETE FROM master_search WHERE rowid = OLD.rowid;
       END
       """,
       """
       CREATE TRIGGER master_search_label_insert AFTER INSERT ON labels
       BEGIN
         UPDATE master_search
         SET labels = COALESCE((SELECT group_concat(label, ' ') FROM labels
                                WHERE master_digest = NEW.master_digest), '')
         WHERE rowid = (SELECT rowid FROM masters WHERE digest = NEW.master_digest);
       END
       """,
       """
       CREATE TRIGGER master_search_label_update AFTER UPDATE ON labels
       BEGIN
         UPDATE master_search
         SET labels = COALESCE((SELECT group_concat(label, ' ') FROM labels
                                WHERE master_digest = OLD.master_digest), '')
         WHERE rowid = (SELECT rowid FROM masters WHERE digest = OLD.master_digest);
         UPDATE master_search
         SET labels = COALESCE((SELECT group_concat(label, ' ') FROM labels
                                WHERE master_digest = NEW.master_digest), '')
         WHERE rowid = (SELECT rowid FROM masters WHERE digest = NEW.master_digest);
       END
       """,
       """
       CREATE TRIGGER master_search_label_delete AFTER DELETE ON labels
       BEGIN
         UPDATE master_search
         SET labels = COALESCE((SELECT group_concat(label, ' ') FROM labels
                                WHERE master_digest = OLD.master_digest), '')
         WHERE rowid = (SELECT rowid FROM masters WHERE digest = OLD.master_digest);
       END
       """
     ]}
  ]

  @doc "Recreates the search projection inside the caller's writer transaction."
  @spec rebuild_search(pid()) :: :ok
  def rebuild_search(connection) do
    Exqlite.query!(connection, "DELETE FROM master_search")
    Exqlite.query!(connection, @search_backfill)
    :ok
  end

  @spec run(pid()) :: :ok | no_return()
  def run(connection) do
    Exqlite.query!(
      connection,
      "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY) STRICT"
    )

    applied =
      connection
      |> Exqlite.query!("SELECT version FROM schema_migrations ORDER BY version")
      |> Map.fetch!(:rows)
      |> MapSet.new(fn [version] -> version end)

    Enum.each(@migrations, fn {version, statements} ->
      unless MapSet.member?(applied, version), do: migrate(connection, version, statements)
    end)

    :ok
  end

  defp migrate(connection, version, statements) do
    {:ok, :migrated} =
      Exqlite.transaction(
        connection,
        fn transaction ->
          Enum.each(statements, &Exqlite.query!(transaction, &1))

          Exqlite.query!(transaction, "INSERT INTO schema_migrations(version) VALUES (?)", [
            version
          ])

          :migrated
        end,
        mode: :immediate
      )
  end
end
