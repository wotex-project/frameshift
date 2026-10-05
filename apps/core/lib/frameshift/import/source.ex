defmodule Frameshift.Import.Source do
  @moduledoc """
  Reads a caller-accessible regular original for the Linux import CLI.

  `with_source/2` opens one bounded nonempty regular file and retains its raw
  descriptor for the callback's lifetime. Pathname and descriptor identities
  must match before and after the initial SHA-256 pass. A symlink, directory,
  empty file, oversized original or changing inode refuses before upload.
  Ownership is not restricted: the caller may import any regular file it can
  read. The service never receives or follows this path.

  ## Stream verification

  `read_chunk/2` seeks only within the admitted source and reads at most 6144
  bytes. An explicit begin may return an earlier acknowledged offset; this does
  not authorize duplicate chunk retries. `verify/1` hashes the complete file
  again under stable descriptor/path custody before finish, detecting changed
  bytes even when filesystem timestamps have coarse resolution. The descriptor
  closes on every callback outcome. Filename normalization affects metadata
  alone and cannot redirect filesystem access.

  Byte ceilings and regular-file checks do not establish installed filesystem
  latency or physical power-loss behavior. An unavailable read returns a finite
  refusal without logging the caller path or original image bytes.
  """

  @maximum_source_bytes 128 * 1024 * 1024
  @stream_chunk_bytes 6_144
  @hash_chunk_bytes 65_536

  @doc "Keeps a verified raw source descriptor private to one bounded import callback."
  @spec with_source(String.t(), (map() -> term())) :: term()
  def with_source(path, callback) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :regular and stat.size in 1..@maximum_source_bytes,
         {:ok, descriptor} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        source = %{
          path: path,
          descriptor: descriptor,
          stat: stat,
          count: stat.size,
          filename: path |> Path.basename() |> String.normalize(:nfc)
        }

        with :ok <- custody(source),
             {:ok, digest} <- hash(source),
             :ok <- custody(source) do
          callback.(Map.put(source, :digest, digest))
        else
          _ -> {:error, :import_source_unavailable}
        end
      after
        :file.close(descriptor)
      end
    else
      _ -> {:error, :import_source_unavailable}
    end
  end

  @doc "Reads one exact next chunk or EOF at the previously admitted source length."
  @spec read_chunk(map(), non_neg_integer()) :: {:ok, binary()} | :eof | {:error, atom()}
  def read_chunk(%{count: count}, count), do: :eof

  def read_chunk(source, offset) when is_integer(offset) and offset >= 0 do
    size = min(source.count - offset, @stream_chunk_bytes)

    with true <- size > 0,
         :ok <- custody(source),
         {:ok, ^offset} <- :file.position(source.descriptor, offset),
         {:ok, bytes} <- :file.read(source.descriptor, size),
         true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      _ -> {:error, :import_source_unavailable}
    end
  end

  def read_chunk(_, _), do: {:error, :import_source_unavailable}

  @doc "Rechecks the complete original and inode before the caller explicitly sends finish."
  @spec verify(map()) :: :ok | {:error, :import_source_unavailable}
  def verify(source) do
    with :ok <- custody(source),
         {:ok, digest} <- hash(source),
         true <- digest == source.digest,
         :ok <- custody(source) do
      :ok
    else
      _ -> {:error, :import_source_unavailable}
    end
  end

  defp custody(source) do
    with {:ok, path_stat} <- File.lstat(source.path, time: :posix),
         {:ok, descriptor_info} <- :file.read_file_info(source.descriptor, time: :posix),
         true <- same?(path_stat, source.stat),
         true <- same?(File.Stat.from_record(descriptor_info), source.stat) do
      :ok
    else
      _ -> {:error, :import_source_unavailable}
    end
  end

  defp same?(left, right) do
    keys = [
      :type,
      :size,
      :mode,
      :uid,
      :gid,
      :links,
      :inode,
      :major_device,
      :minor_device,
      :mtime,
      :ctime
    ]

    Map.take(left, keys) == Map.take(right, keys)
  end

  defp hash(source) do
    with {:ok, 0} <- :file.position(source.descriptor, 0),
         {:ok, context} <-
           hash_chunks(source.descriptor, source.count, :crypto.hash_init(:sha256)),
         :eof <- :file.read(source.descriptor, 1) do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash_final(context), case: :lower)}
    else
      _ -> {:error, :import_source_unavailable}
    end
  end

  defp hash_chunks(_, 0, context), do: {:ok, context}

  defp hash_chunks(descriptor, remaining, context) do
    case :file.read(descriptor, min(remaining, @hash_chunk_bytes)) do
      {:ok, bytes} when byte_size(bytes) in 1..remaining//1 ->
        hash_chunks(descriptor, remaining - byte_size(bytes), :crypto.hash_update(context, bytes))

      _ ->
        {:error, :import_source_unavailable}
    end
  end
end
