defmodule Frameshift.Paths do
  @moduledoc """
  Resolves relocatable native data and local IPC locations.

  `data_dir/0` defaults to the operating system's user-data directory for
  Frameshift and accepts an expanded `FRAMESHIFT_DATA_DIR` override.
  `socket_path/0` defaults to `core.sock` beneath that root, with an explicit
  `FRAMESHIFT_SOCKET_PATH` override. Paths do not embed a build-machine home.

  ## Diagnostics and admission

  `diagnostics_socket_path/0` defaults to `d.sock` beside the command socket or
  uses `FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH`. Resolution alone creates no directory
  or listener and does not establish permissions. The IPC owners separately
  admit private directories, bounded socket names and authenticated peers before
  serving commands or read-only diagnostics.
  """

  @spec data_dir() :: String.t()
  def data_dir do
    case System.get_env("FRAMESHIFT_DATA_DIR") do
      nil -> :filename.basedir(:user_data, "Frameshift") |> to_string()
      path -> Path.expand(path)
    end
  end

  @spec socket_path() :: String.t()
  def socket_path do
    case System.get_env("FRAMESHIFT_SOCKET_PATH") do
      nil -> Path.join(data_dir(), "core.sock")
      path -> Path.expand(path)
    end
  end

  @doc "Returns the read-only local diagnostics socket beside the command socket."
  @spec diagnostics_socket_path() :: String.t()
  def diagnostics_socket_path do
    case System.get_env("FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH") do
      nil -> Path.join(Path.dirname(socket_path()), "d.sock")
      path -> Path.expand(path)
    end
  end
end
