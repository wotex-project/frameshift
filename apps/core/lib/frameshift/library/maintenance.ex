defmodule Frameshift.Library.Maintenance do
  @moduledoc """
  Runs fixed packaged backup, verification and offline restore operations.

  `run/0` reads the selected operation/source/destination from the dedicated
  maintenance environment variables and the data root from `Frameshift.Paths`.
  It prints a finite success/error result and exits with status 0 or 1; supplied
  paths never become evaluated Elixir source.

  ## Operation lifecycle

  `execute/4` validates the operation's argument combination. Backup checks for
  an existing stopped library, starts a temporary unnamed owner and stops it
  after creation. Verification opens the backup validation path; restore requires
  the destination library to be stopped before copying into an absent root.

  Live command sockets prevent offline operations from proceeding. Invalid
  arguments, unsafe stores or unavailable state return errors instead of resetting
  or merging data. `Frameshift.Library.Backup` owns content/manifest verification
  and staged publication; this module owns the packaged invocation and exit code.
  """

  alias Frameshift.Library
  alias Frameshift.Library.Backup
  alias Frameshift.Paths

  @spec run() :: no_return()
  def run do
    operation = System.get_env("FRAMESHIFT_MAINTENANCE_OPERATION")
    source = System.get_env("FRAMESHIFT_MAINTENANCE_SOURCE")
    destination = System.get_env("FRAMESHIFT_MAINTENANCE_DESTINATION")

    case execute(operation, source, destination, Paths.data_dir()) do
      :ok ->
        IO.puts("#{operation}: ok")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "#{operation}: #{format_error(reason)}")
        System.halt(1)
    end
  end

  @spec execute(String.t() | nil, String.t() | nil, String.t() | nil, String.t()) ::
          :ok | {:error, term()}
  def execute("backup", nil, destination, data_dir) when is_binary(destination) do
    with :ok <- existing_library(data_dir),
         :ok <- stopped_library(data_dir),
         {:ok, _} <- Application.ensure_all_started(:exqlite),
         {:ok, library} <- Library.start_link(data_dir: data_dir, name: nil) do
      try do
        Library.create_backup(library, destination)
      after
        GenServer.stop(library)
      end
    end
  end

  def execute("verify", source, nil, _) when is_binary(source) do
    with {:ok, _} <- Application.ensure_all_started(:exqlite) do
      Backup.verify(source)
    end
  end

  def execute("restore", source, destination, _)
      when is_binary(source) and is_binary(destination) do
    with :ok <- stopped_library(destination),
         {:ok, _} <- Application.ensure_all_started(:exqlite) do
      Backup.restore(source, destination)
    end
  end

  def execute(_, _, _, _), do: {:error, :invalid_arguments}

  defp existing_library(data_dir) do
    case File.lstat(Path.join(data_dir, "metadata.sqlite")) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, :invalid_library_database}
      {:error, :enoent} -> {:error, :library_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stopped_library(data_dir) do
    root = Path.expand(data_dir)
    default_socket = Path.join(root, "core.sock")

    sockets =
      if root == Paths.data_dir() do
        Enum.uniq([default_socket, Paths.socket_path()])
      else
        [default_socket]
      end

    Enum.reduce_while(sockets, :ok, fn socket, :ok ->
      case socket_status(socket) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp socket_status(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :other}} -> probe_socket(path)
      {:ok, _} -> {:error, :core_socket_present}
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe_socket(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, :core_socket_present}

      {:error, reason} when reason in [:econnrefused, :enoent] ->
        :ok

      {:error, _} ->
        {:error, :core_socket_present}
    end
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(_), do: "maintenance_failed"
end
