defmodule Frameshift.LocalIPC.SocketDirectory do
  @moduledoc """
  Admits bounded Unix socket paths under private or Linux group access policy.

  `prepare/1` creates the parent if needed, checks its final inode with
  `File.lstat/1` and restricts it to `0700`. The private listener owns stale
  endpoint handling, socket mode `0600` and same-UID authentication.

  ## Linux observer access

  `prepare_group/2` requires a nonroot Linux service with identical real,
  effective, saved and filesystem UIDs. The final directory and any existing
  socket must belong to that identity. Symlinks, non-socket placeholders and
  live endpoints refuse before group or mode changes. An owned stale socket
  can be removed after a bounded connection check. The admitted directory has
  the configured GID and exact mode `0710`.

  `restrict_group_socket/3` admits a newly bound socket with that owner, GID and
  mode `0660`. `validate_group_socket/3` rechecks both final inodes before a
  listener dispatches each accepted connection. Linux pathname permissions
  enforce supplementary-group access; the listener must additionally read
  actual kernel peer credentials and enforce its read-only request contract.

  ## Limits and custody

  Paths are UTF-8, absolute, NUL-free and at most 100 bytes in the group policy.
  Invalid policy never silently falls back to private access. These checks do
  not inspect every ancestor or provide descriptor-relative race protection
  against root or the service owner modifying the managed directory tree.
  Provisioning users/groups and retaining listener handles remain the package
  and listener owners' responsibilities. No caller JSON selects this policy.
  """

  @maximum_id 4_294_967_294
  @maximum_status_bytes 65_536

  @spec prepare(String.t()) :: :ok | {:error, :socket_path_too_long | :unsafe_socket_directory}
  def prepare(path) when is_binary(path) do
    if byte_size(path) > 100 do
      {:error, :socket_path_too_long}
    else
      prepare_directory(Path.dirname(path))
    end
  end

  @doc "Prepares an owned Linux observer directory and returns the admitted service UID."
  @spec prepare_group(String.t(), pos_integer()) :: {:ok, pos_integer()} | {:error, atom()}
  def prepare_group(path, gid) do
    with :ok <- group_configuration(path, gid),
         {:ok, uid} <- service_uid(),
         :ok <- owned_directory(Path.dirname(path), uid),
         :ok <- remove_owned_stale_socket(path, uid),
         :ok <- File.chgrp(Path.dirname(path), gid),
         :ok <- File.chmod(Path.dirname(path), 0o710),
         :ok <- validate_inode(Path.dirname(path), :directory, uid, gid, 0o710) do
      {:ok, uid}
    end
  end

  @doc "Restricts a newly bound Linux observer socket without changing its UID."
  @spec restrict_group_socket(String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, atom()}
  def restrict_group_socket(path, gid, uid) do
    with :ok <- group_configuration(path, gid),
         {:ok, stat} <- File.lstat(path),
         true <- socket_inode?(stat) and stat.uid == uid,
         :ok <- File.chgrp(path, gid),
         :ok <- File.chmod(path, 0o660) do
      validate_group_socket(path, gid, uid)
    else
      _ -> {:error, :unsafe_socket_path}
    end
  end

  @doc "Checks the exact final directory and socket custody before read-only dispatch."
  @spec validate_group_socket(String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, atom()}
  def validate_group_socket(path, gid, uid) do
    with :ok <- group_configuration(path, gid),
         :ok <- validate_inode(Path.dirname(path), :directory, uid, gid, 0o710) do
      validate_inode(path, :socket, uid, gid, 0o660)
    end
  end

  defp group_configuration(path, gid) do
    cond do
      :os.type() != {:unix, :linux} -> {:error, :unsupported_group_socket}
      not is_integer(gid) or gid not in 1..@maximum_id -> {:error, :invalid_socket_group}
      true -> group_path(path)
    end
  end

  defp group_path(path) when is_binary(path) do
    cond do
      byte_size(path) > 100 -> {:error, :socket_path_too_long}
      not String.valid?(path) or String.contains?(path, <<0>>) -> {:error, :unsafe_socket_path}
      Path.type(path) != :absolute -> {:error, :unsafe_socket_path}
      true -> :ok
    end
  end

  defp group_path(_), do: {:error, :unsafe_socket_path}

  defp service_uid do
    with {:ok, file} <- File.open("/proc/self/status", [:read, :binary]) do
      bytes = IO.binread(file, @maximum_status_bytes + 1)
      File.close(file)
      status_uid(bytes)
    end
  end

  defp status_uid(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum_status_bytes do
    rows = bytes |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Uid:"))

    with [row] <- rows,
         ["Uid:", real, effective, saved, filesystem] <- String.split(row),
         {uid, ""} <- Integer.parse(real),
         true <- real == effective and real == saved and real == filesystem,
         true <- uid in 0..@maximum_id do
      if uid == 0, do: {:error, :unprivileged_service_required}, else: {:ok, uid}
    else
      _ -> {:error, :invalid_service_identity}
    end
  end

  defp status_uid(_), do: {:error, :invalid_service_identity}

  defp owned_directory(parent, uid) do
    with :ok <- File.mkdir_p(parent),
         {:ok, %File.Stat{type: :directory, uid: ^uid}} <- File.lstat(parent) do
      :ok
    else
      _ -> {:error, :unsafe_socket_directory}
    end
  end

  defp remove_owned_stale_socket(path, uid) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, stat} -> check_owned_stale_socket(path, stat, uid)
      _ -> {:error, :unsafe_socket_path}
    end
  end

  defp check_owned_stale_socket(path, stat, uid) do
    with true <- socket_inode?(stat) and stat.uid == uid,
         {:ok, socket} <- :socket.open(:local, :stream, :default) do
      result = :socket.connect(socket, %{family: :local, path: path}, 250)
      :socket.close(socket)

      case result do
        :ok -> {:error, :socket_already_active}
        {:error, :econnrefused} -> File.rm(path)
        _ -> {:error, :socket_path_busy}
      end
    else
      _ -> {:error, :unsafe_socket_path}
    end
  end

  defp validate_inode(path, type, uid, gid, permissions) do
    with {:ok, stat} <- File.lstat(path),
         true <- if(type == :socket, do: socket_inode?(stat), else: stat.type == type),
         true <- stat.uid == uid and stat.gid == gid,
         true <- Bitwise.band(stat.mode, 0o7777) == permissions do
      :ok
    else
      _ -> {:error, :unsafe_socket_permissions}
    end
  end

  defp socket_inode?(stat), do: Bitwise.band(stat.mode, 0o170000) == 0o140000

  defp prepare_directory(parent) do
    with :ok <- File.mkdir_p(parent),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(parent),
         :ok <- File.chmod(parent, 0o700),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(parent),
         true <- Bitwise.band(mode, 0o077) == 0 do
      :ok
    else
      _ -> {:error, :unsafe_socket_directory}
    end
  end
end
