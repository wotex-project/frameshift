defmodule Frameshift.Import.Stage do
  @moduledoc """
  Owns exclusive private files for bounded Linux original-byte intake.

  `prepare/0` creates a fixed replacement fence beneath the existing real,
  nonroot 0700 temporary directory. Existing custody refuses; unknown bytes are
  never adopted. `create/1` generates an exclusive 0600 regular file unrelated
  to the caller filename. Each append checks directory, pathname and descriptor
  identity and exact acknowledged length before seeking or writing.

  ## Sealing and cleanup

  `seal/3` synchronizes the descriptor and reads bounded original bytes under
  stable before/after custody, then verifies exact length and source digest.
  Only this verified binary may reach the codec. A successful append is an
  intake observation, not a durable command claim or power-loss guarantee.

  `discard/1` removes only the matching owned inode. `release/1` removes only
  an empty matching directory. Changed custody or unknown task/native lifetime
  must preserve the fence for explicit stopped-service recovery. These helpers
  never recursively delete a directory or follow caller-provided paths.
  """

  import Bitwise

  alias Frameshift.Digest

  @chunk_bytes 65_536
  @maximum_source_bytes 128 * 1024 * 1024

  @doc "Creates exclusive staging custody without replacing a previous owner's fence."
  @spec prepare() :: {:ok, map()} | {:error, :import_unavailable}
  def prepare do
    root = System.tmp_dir!()
    path = Path.join(root, "frameshift-import-custody")

    with {:ok, root_stat} <- private_directory(root),
         :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700),
         {:ok, directory_stat} <- private_directory(path),
         true <- directory_stat.uid == root_stat.uid do
      {:ok, %{path: path, root: root, root_stat: root_stat, stat: directory_stat}}
    else
      _ -> {:error, :import_unavailable}
    end
  end

  @doc "Creates one generated exclusive file and captures its initial custody."
  @spec create(map()) :: {:ok, map()} | {:error, :import_stage_unavailable}
  def create(directory) do
    path = Path.join(directory.path, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    with :ok <- directory_custody(directory),
         {:ok, descriptor} <-
           :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             {:ok, stat} <- descriptor_stat(descriptor),
             true <- regular?(stat, directory.stat.uid, 0),
             :ok <- pathname_custody(path, stat) do
          {:ok, %{path: path, directory: directory, stat: stat, offset: 0}}
        else
          _ -> {:error, :import_stage_unavailable}
        end
      after
        :file.close(descriptor)
      end
    else
      _ -> {:error, :import_stage_unavailable}
    end
  end

  @doc "Appends once at the observed length; partial or unsafe writes never advance acknowledgement."
  @spec append(map(), binary()) :: {:ok, map()} | {:error, :import_stage_unavailable}
  def append(stage, bytes) do
    with :ok <- directory_custody(stage.directory),
         :ok <- pathname_custody(stage.path, stage.stat),
         {:ok, descriptor} <- open(stage.path) do
      try do
        with {:ok, before} <- descriptor_stat(descriptor),
             true <- same?(before, stage.stat),
             {:ok, offset} when offset == stage.offset <- :file.position(descriptor, :eof),
             :ok <- :file.write(descriptor, bytes),
             {:ok, after_write} <- descriptor_stat(descriptor),
             true <- unchanged_inode?(before, after_write),
             true <- after_write.size == stage.offset + byte_size(bytes),
             :ok <- pathname_custody(stage.path, after_write),
             :ok <- directory_custody(stage.directory) do
          {:ok, %{stage | stat: after_write, offset: after_write.size}}
        else
          _ -> {:error, :import_stage_unavailable}
        end
      after
        :file.close(descriptor)
      end
    else
      _ -> {:error, :import_stage_unavailable}
    end
  end

  @doc "Synchronizes and verifies complete original bytes through stable descriptor custody."
  @spec seal(map(), pos_integer(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def seal(stage, count, digest) when count in 1..@maximum_source_bytes do
    with :ok <- directory_custody(stage.directory),
         :ok <- pathname_custody(stage.path, stage.stat),
         {:ok, descriptor} <- open(stage.path) do
      try do
        with {:ok, before} <- descriptor_stat(descriptor),
             true <- same?(before, stage.stat) and before.size == count,
             :ok <- :file.sync(descriptor),
             {:ok, bytes} <- read(descriptor, count, []),
             :eof <- :file.read(descriptor, 1),
             {:ok, after_read} <- descriptor_stat(descriptor),
             true <- same?(before, after_read),
             :ok <- pathname_custody(stage.path, after_read),
             :ok <- directory_custody(stage.directory) do
          if Digest.sha256(bytes) == digest,
            do: {:ok, bytes},
            else: {:error, :import_source_mismatch}
        else
          _ -> {:error, :import_stage_unavailable}
        end
      after
        :file.close(descriptor)
      end
    else
      _ -> {:error, :import_stage_unavailable}
    end
  end

  @doc "Removes a known stage only while its inode remains in the owned directory."
  @spec discard(map()) :: :ok | {:error, :import_stage_unavailable}
  def discard(stage) do
    with :ok <- directory_custody(stage.directory),
         {:ok, stat} <- File.lstat(stage.path, time: :posix),
         true <- unchanged_inode?(stage.stat, stat),
         :ok <- File.rm(stage.path) do
      :ok
    else
      _ -> {:error, :import_stage_unavailable}
    end
  end

  @doc "Removes an empty known fence; unrelated or retained files make release refuse."
  @spec release(map()) :: :ok | {:error, atom()}
  def release(directory) do
    with :ok <- directory_custody(directory), do: File.rmdir(directory.path)
  end

  defp open(path), do: :file.open(String.to_charlist(path), [:raw, :binary, :read, :write])

  defp descriptor_stat(descriptor) do
    case :file.read_file_info(descriptor, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      error -> error
    end
  end

  defp private_directory(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory, uid: uid, mode: mode} = stat}
      when uid > 0 and (mode &&& 0o7777) == 0o700 ->
        {:ok, stat}

      _ ->
        {:error, :import_stage_unavailable}
    end
  end

  defp directory_custody(directory) do
    with {:ok, root} <- private_directory(directory.root),
         {:ok, stat} <- private_directory(directory.path),
         true <- same_directory?(root, directory.root_stat),
         true <- same_directory?(stat, directory.stat) do
      :ok
    else
      _ -> {:error, :import_stage_unavailable}
    end
  end

  defp pathname_custody(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> if same?(stat, expected), do: :ok, else: {:error, :import_stage_unavailable}
      _ -> {:error, :import_stage_unavailable}
    end
  end

  defp regular?(stat, uid, size),
    do:
      stat.type == :regular and stat.uid == uid and stat.size == size and
        (stat.mode &&& 0o7777) == 0o600 and stat.links == 1

  defp same?(left, right),
    do:
      unchanged_inode?(left, right) and left.size == right.size and
        left.mtime == right.mtime and left.ctime == right.ctime

  defp unchanged_inode?(left, right),
    do:
      Map.take(left, [:type, :uid, :gid, :mode, :links, :inode, :major_device, :minor_device]) ==
        Map.take(right, [:type, :uid, :gid, :mode, :links, :inode, :major_device, :minor_device])

  defp same_directory?(left, right),
    do:
      Map.take(left, [:type, :uid, :gid, :mode, :inode, :major_device, :minor_device]) ==
        Map.take(right, [:type, :uid, :gid, :mode, :inode, :major_device, :minor_device])

  defp read(_, 0, chunks), do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read(descriptor, remaining, chunks) do
    case :file.read(descriptor, min(remaining, @chunk_bytes)) do
      {:ok, bytes} when byte_size(bytes) in 1..remaining//1 ->
        read(descriptor, remaining - byte_size(bytes), [bytes | chunks])

      _ ->
        {:error, :import_stage_unavailable}
    end
  end
end
