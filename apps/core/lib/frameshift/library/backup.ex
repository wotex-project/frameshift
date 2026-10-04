defmodule Frameshift.Library.Backup do
  @moduledoc """
  Creates verified private library snapshots and validates offline restores.

  `create/3` is called by `Frameshift.Library` while its GenServer serializes
  object changes. It snapshots SQLite, copies referenced objects and writes an
  exact digest manifest in a private staging directory. Verification completes
  before the staged directory is published to an absent destination outside the
  live data root.

  Directory synchronization uses OTP's explicit `:directory` mode and requires
  a successful sync; an unsupported or refused open cannot count as persistence.
  If parent synchronization fails after rename, `{:commit_uncertain, reason}`
  preserves the published destination for deliberate offline inspection.

  ## Restore boundary

  `verify/1` checks the manifest, database and object closure, including expected
  bytes and digests. `restore/2` requires an absent destination and a stopped
  library, copies only admitted files, verifies the staged result and rebuilds
  search before publication. It does not merge into a running or existing store.

  Use `Frameshift.Library.Maintenance` for the packaged offline entrypoint.
  Corrupt/missing objects or unsafe destinations return errors; failed staging
  is cleaned up rather than presenting a partial backup as a completed snapshot.
  A valid backup proves retained local custody, not live frame or provider state.
  """

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Library.Migrations

  @maximum_manifest_bytes 64 * 1024 * 1024

  @spec create(pid(), String.t(), String.t()) :: :ok | {:error, term()}
  def create(connection, data_dir, destination) when is_binary(destination) do
    destination = Path.expand(destination)

    with :ok <- absent_destination(destination),
         :ok <- outside_data_root(data_dir, destination),
         {:ok, stage} <- make_stage(destination) do
      result = create_staged(connection, data_dir, stage, destination)
      if result != :ok, do: File.rm_rf(stage)
      result
    end
  end

  def create(_, _, _), do: {:error, :invalid_backup_destination}

  @spec restore(String.t(), String.t()) :: :ok | {:error, term()}
  def restore(backup, destination) when is_binary(backup) and is_binary(destination) do
    backup = Path.expand(backup)
    destination = Path.expand(destination)

    with :ok <- absent_destination(destination),
         :ok <- verify(backup),
         {:ok, stage} <- make_stage(destination) do
      result = restore_staged(backup, stage, destination)
      if result != :ok, do: File.rm_rf(stage)
      result
    end
  end

  def restore(_, _), do: {:error, :invalid_backup_path}

  @spec verify(String.t()) :: :ok | {:error, term()}
  def verify(root) do
    with {:ok, manifest} <- read_manifest(root),
         :ok <- verify_file(Path.join(root, "metadata.sqlite"), manifest["databaseDigest"], nil),
         :ok <- verify_database(root, manifest),
         :ok <- verify_objects(root, manifest["objects"]) do
      :ok
    end
  end

  defp create_staged(connection, data_dir, stage, destination) do
    database = Path.join(stage, "metadata.sqlite")

    with {:ok, _} <- Exqlite.query(connection, "VACUUM INTO ?", [database]),
         :ok <- File.chmod(database, 0o600),
         {:ok, rows} <- object_rows(connection),
         :ok <- copy_objects(data_dir, stage, rows),
         {:ok, database_digest} <- hash_file(database),
         :ok <- write_manifest(stage, database_digest, rows),
         :ok <- verify(stage),
         :ok <- publish(stage, destination) do
      :ok
    end
  end

  defp restore_staged(backup, stage, destination) do
    with :ok <-
           copy_regular(Path.join(backup, "metadata.sqlite"), Path.join(stage, "metadata.sqlite")),
         {:ok, manifest} <- read_manifest(backup),
         :ok <- copy_objects(backup, stage, manifest["objects"]),
         :ok <-
           copy_regular(Path.join(backup, "manifest.json"), Path.join(stage, "manifest.json")),
         :ok <- verify(stage),
         :ok <- rebuild_search(stage),
         :ok <- File.rm(Path.join(stage, "manifest.json")),
         :ok <- publish(stage, destination) do
      :ok
    end
  end

  defp object_rows(connection) do
    case Exqlite.query(
           connection,
           "SELECT digest, byte_count, storage_state FROM objects ORDER BY digest"
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [digest, size, placement] ->
           %{"digest" => digest, "byteCount" => size, "storageState" => placement}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_objects(source, destination, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      with :ok <- validate_object(row),
           from <- object_path(source, row),
           to <- object_path(destination, row),
           :ok <- File.mkdir_p(Path.dirname(to)),
           :ok <- copy_regular(from, to),
           :ok <- verify_file(to, row["digest"], row["byteCount"]),
           :ok <- sync_directory(Path.dirname(to)) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_objects(root, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      with :ok <- validate_object(row),
           :ok <- verify_file(object_path(root, row), row["digest"], row["byteCount"]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp object_path(root, %{"digest" => digest, "storageState" => "active"}),
    do: ContentStore.object_path(root, digest)

  defp object_path(root, %{"digest" => digest, "storageState" => "trash"}),
    do: ContentStore.trash_path(root, digest)

  defp validate_object(%{"digest" => digest, "byteCount" => size, "storageState" => placement})
       when is_integer(size) and size >= 0 and placement in ["active", "trash"] do
    if Digest.valid_sha256?(digest), do: :ok, else: {:error, :invalid_backup_object}
  end

  defp validate_object(_), do: {:error, :invalid_backup_object}

  defp write_manifest(root, database_digest, rows) do
    bytes =
      RFC8785.encode!(%{
        "version" => 1,
        "databaseDigest" => database_digest,
        "objects" => rows
      })

    write_synced(Path.join(root, "manifest.json"), bytes)
  end

  defp read_manifest(root) do
    path = Path.join(root, "manifest.json")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @maximum_manifest_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"version" => 1, "databaseDigest" => digest, "objects" => rows} = manifest} <-
           Wotex.JSON.decode(bytes,
             max_bytes: @maximum_manifest_bytes,
             max_depth: 8,
             max_nodes: 500_000,
             max_string_bytes: 1_024,
             max_collection_size: 100_000
           ),
         true <- Digest.valid_sha256?(digest) and is_list(rows),
         true <- length(rows) <= 100_000 do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_backup_manifest}
    end
  end

  defp verify_database(root, manifest) do
    database = Path.join(root, "metadata.sqlite")

    with {:ok, connection} <-
           Exqlite.start_link(database: database, mode: :readonly, foreign_keys: :on) do
      try do
        with :ok <- verify_database_integrity(connection),
             {:ok, rows} <- object_rows(connection),
             true <- rows == manifest["objects"] do
          :ok
        else
          _ -> {:error, :invalid_backup_database}
        end
      after
        GenServer.stop(connection)
      end
    end
  end

  defp rebuild_search(root) do
    database = Path.join(root, "metadata.sqlite")

    with {:ok, connection} <-
           Exqlite.start_link(database: database, mode: :readwrite, foreign_keys: :on) do
      try do
        case Exqlite.transaction(connection, &Migrations.rebuild_search/1, mode: :immediate) do
          {:ok, :ok} -> verify_database_integrity(connection)
          {:error, reason} -> {:error, reason}
        end
      after
        GenServer.stop(connection)
      end
    end
  end

  defp verify_file(path, expected_digest, expected_size) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- is_nil(expected_size) or size == expected_size,
         {:ok, digest} <- hash_file(path),
         true <- digest == expected_digest do
      :ok
    else
      _ -> {:error, :invalid_backup_file}
    end
  end

  defp verify_database_integrity(connection) do
    with {:ok, %{rows: [["ok"]]}} <- Exqlite.query(connection, "PRAGMA integrity_check"),
         {:ok, %{rows: []}} <- Exqlite.query(connection, "PRAGMA foreign_key_check") do
      :ok
    else
      _ -> {:error, :invalid_backup_database}
    end
  end

  defp hash_file(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        hash_chunks(file, :crypto.hash_init(:sha256))
      after
        File.close(file)
      end
    end
  end

  defp hash_chunks(file, state) do
    case IO.binread(file, 64 * 1024) do
      :eof -> {:ok, "sha256:" <> Base.encode16(:crypto.hash_final(state), case: :lower)}
      {:error, reason} -> {:error, reason}
      bytes -> hash_chunks(file, :crypto.hash_update(state, bytes))
    end
  end

  defp copy_regular(source, destination) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(source),
         {:ok, _} <- File.copy(source, destination),
         :ok <- File.chmod(destination, 0o600),
         :ok <- sync_file(destination) do
      :ok
    else
      _ -> {:error, :backup_copy_failed}
    end
  end

  defp write_synced(path, bytes) do
    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(file, bytes),
             do: :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp publish(stage, destination) do
    with :ok <- absent_destination(destination),
         :ok <- sync_directory(stage),
         :ok <- File.rename(stage, destination) do
      case sync_directory(Path.dirname(destination)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:commit_uncertain, reason}}
      end
    end
  end

  defp sync_file(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        try do
          :file.sync(directory)
        after
          :file.close(directory)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp absent_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> {:error, :backup_destination_exists}
    end
  end

  defp outside_data_root(data_dir, destination) do
    root = Path.expand(data_dir)

    if destination == root or String.starts_with?(destination, root <> "/"),
      do: {:error, :backup_inside_library},
      else: :ok
  end

  defp make_stage(destination) do
    stage =
      destination <> ".partial-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.mkdir(stage) do
      case File.chmod(stage, 0o700) do
        :ok ->
          {:ok, stage}

        {:error, reason} ->
          File.rmdir(stage)
          {:error, reason}
      end
    end
  end
end
