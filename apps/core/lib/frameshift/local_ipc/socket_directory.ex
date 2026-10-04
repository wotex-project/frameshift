defmodule Frameshift.LocalIPC.SocketDirectory do
  @moduledoc """
  Admits the private parent directory of a bounded Unix socket path.

  `prepare/1` refuses socket paths longer than 100 bytes, creates the parent if
  needed, checks the final directory with `File.lstat/1` and restricts it to
  mode `0700`. A final symlink, non-directory or permission failure returns
  `:unsafe_socket_directory` rather than starting a listener in that target.

  ## Listener responsibilities

  This helper prepares the containing directory only; it does not bind a socket,
  remove an existing endpoint, authenticate a peer or inspect every ancestor.
  The command and diagnostic owners separately handle stale/live socket checks,
  mode `0600`, bounded framing and their respective authentication policy.
  """

  @spec prepare(String.t()) :: :ok | {:error, :socket_path_too_long | :unsafe_socket_directory}
  def prepare(path) when is_binary(path) do
    if byte_size(path) > 100 do
      {:error, :socket_path_too_long}
    else
      prepare_directory(Path.dirname(path))
    end
  end

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
