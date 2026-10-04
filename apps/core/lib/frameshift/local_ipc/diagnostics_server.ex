defmodule Frameshift.LocalIPC.DiagnosticsServer do
  @moduledoc """
  Serves peer-authenticated read-only diagnostics over an owned Unix socket.

  `start_link/1` receives the path and owned library/metrics/task boundaries.
  By default the directory/socket are private and the kernel-reported peer UID
  must match the directory owner. Linux may explicitly select `:group_gid`: an
  unprivileged service owns a `0710` directory and `0660` socket, pathname
  permissions enforce primary/supplementary group access, and each connection
  must supply valid kernel PID/UID/GID credentials. Final inode custody is checked
  again before dispatch. Unsupported or invalid policy fails closed; the shell
  command bootstrap token is not accepted here.

  ## Requests and lifecycle

  One connection carries a length-framed JSON request of at most 8 KiB and a
  response of at most 256 KiB, with a five-second deadline and at most 16 clients.
  The finite query set reads catalog/health/metric/redacted-audit projections;
  there is no generic SQL, library mutation or network-effect dispatch.

  The process monitors its acceptor and closes/unlinks its socket during shutdown.
  `Frameshift.LocalIPC.Server` is a different command endpoint with its own token
  and receipt contract. Diagnostics availability does not establish full collector
  coverage or grant access to private artwork and credential material.
  """

  use GenServer

  alias Frameshift.Diagnostics.{Catalog, FallbackLog, Metrics}
  alias Frameshift.Library
  alias Frameshift.LocalIPC.PeerIdentity
  alias Frameshift.LocalIPC.SocketDirectory

  @maximum_request_bytes 8_192
  @maximum_response_bytes 256 * 1024
  @request_timeout_ms 5_000
  @maximum_clients 16

  defmodule State do
    @moduledoc """
    Tracks the diagnostic listener, private path and supervised acceptor.

    The owner monitors the acceptor and retains the socket handle so shutdown can
    close it and unlink the endpoint. Individual client workers receive bounded
    read-only dependencies, not ownership of the listener or permission to dispatch
    native commands.

    ## Process lifetime

    `Frameshift.LocalIPC.DiagnosticsServer` constructs this state after directory,
    socket and peer policy setup. It is transient and not a persisted diagnostic
    record. Restart must re-establish the endpoint's permissions and authentication
    rather than reviving an old socket handle.
    """

    @type t :: %__MODULE__{listener: :socket.socket(), path: String.t(), acceptor: pid()}

    @enforce_keys [:listener, :path, :acceptor]
    defstruct [:listener, :path, :acceptor]
  end

  @doc "Starts an owned read-only socket with private or explicit Linux observer access."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    path = options |> Keyword.fetch!(:path) |> Path.expand()
    library = Keyword.get(options, :library, Library)
    metrics = Keyword.get(options, :metrics, Metrics)
    task_supervisor = Keyword.get(options, :task_supervisor, Frameshift.DiagnosticsTaskSupervisor)

    with {:ok, policy} <- prepare_path(path, Keyword.get(options, :group_gid)),
         {:ok, listener} <- open_listener(path, policy) do
      start_acceptor(listener, path, policy, library, metrics, task_supervisor)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_acceptor(listener, path, policy, library, metrics, tasks) do
    case Task.Supervisor.start_child(tasks, fn ->
           accept_loop(listener, policy, library, metrics, tasks, [])
         end) do
      {:ok, acceptor} ->
        Process.monitor(acceptor)
        {:ok, %State{listener: listener, path: path, acceptor: acceptor}}

      {:error, reason} ->
        :socket.close(listener)
        File.rm(path)
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, _, :process, acceptor, reason},
        %State{acceptor: acceptor} = state
      ) do
    {:stop, {:acceptor_stopped, reason}, state}
  end

  @impl true
  def terminate(_, %State{listener: listener, path: path}) do
    :socket.close(listener)
    File.rm(path)
    :ok
  end

  defp prepare_path(path, nil) do
    with :ok <- SocketDirectory.prepare(path),
         :ok <- remove_stale_socket(path),
         {:ok, directory} <- File.lstat(Path.dirname(path)) do
      {:ok, {:private, directory.uid}}
    else
      {:error, :unsafe_socket_directory} -> {:error, :unsafe_diagnostics_directory}
      error -> error
    end
  end

  defp prepare_path(path, gid) do
    with {:ok, uid} <- SocketDirectory.prepare_group(path, gid) do
      {:ok, {:group, path, gid, uid}}
    end
  end

  defp open_listener(path, policy) do
    with {:ok, listener} <- :socket.open(:local, :stream, :default) do
      case :socket.bind(listener, %{family: :local, path: path}) do
        :ok ->
          finish_listener(listener, path, policy)

        {:error, reason} ->
          :socket.close(listener)
          {:error, reason}
      end
    end
  end

  defp finish_listener(listener, path, policy) do
    with :ok <- restrict_socket(path, policy),
         :ok <- :socket.listen(listener, 16) do
      {:ok, listener}
    else
      {:error, reason} ->
        :socket.close(listener)
        File.rm(path)
        {:error, reason}
    end
  end

  defp restrict_socket(path, {:private, _}), do: File.chmod(path, 0o600)

  defp restrict_socket(path, {:group, _, gid, uid}),
    do: SocketDirectory.restrict_group_socket(path, gid, uid)

  defp remove_stale_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :other}} ->
        with {:ok, socket} <- :socket.open(:local, :stream, :default) do
          check_stale_socket(socket, path)
        end

      _ ->
        {:error, :unsafe_socket_path}
    end
  end

  defp check_stale_socket(socket, path) do
    result = :socket.connect(socket, %{family: :local, path: path})
    :socket.close(socket)

    case result do
      :ok -> {:error, :socket_already_active}
      {:error, :econnrefused} -> File.rm(path)
      _ -> {:error, :socket_path_busy}
    end
  end

  defp accept_loop(listener, policy, library, metrics, task_supervisor, workers) do
    case :socket.accept(listener) do
      {:ok, socket} ->
        live_workers = Enum.filter(workers, &Process.alive?/1)

        next_workers =
          dispatch_client(socket, policy, library, metrics, task_supervisor, live_workers)

        accept_loop(listener, policy, library, metrics, task_supervisor, next_workers)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:diagnostics_accept_failed, reason})
    end
  end

  defp dispatch_client(socket, _, _, _, _, workers)
       when length(workers) >= @maximum_clients do
    :socket.close(socket)
    workers
  end

  defp dispatch_client(socket, policy, library, metrics, tasks, workers) do
    case Task.Supervisor.start_child(tasks, fn -> serve(socket, policy, library, metrics) end) do
      {:ok, worker} ->
        [worker | workers]

      {:error, _} ->
        :socket.close(socket)
        workers
    end
  end

  defp serve(socket, policy, library, metrics) do
    response =
      with :ok <- authorize(socket, policy),
           {:ok, payload} <- read_request(socket),
           {:ok, request} <- decode_request(payload) do
        dispatch(request, library, metrics)
      else
        {:error, :authentication_required} -> error_response(nil, :authentication_required)
        {:error, _} -> error_response(nil, :invalid_request)
      end

    encoded = RFC8785.encode!(response)

    if byte_size(encoded) <= @maximum_response_bytes do
      :socket.send(socket, <<byte_size(encoded)::unsigned-big-32, encoded::binary>>)
    end

    :socket.close(socket)
  catch
    _, _ ->
      :socket.close(socket)
  end

  defp authorize(socket, {:private, owner_uid}) do
    case PeerIdentity.uid(socket) do
      {:ok, ^owner_uid} -> :ok
      _ -> {:error, :authentication_required}
    end
  end

  defp authorize(socket, {:group, path, gid, uid}) do
    with :ok <- SocketDirectory.validate_group_socket(path, gid, uid),
         {:ok, _} <- PeerIdentity.credentials(socket) do
      :ok
    else
      _ -> {:error, :authentication_required}
    end
  end

  defp read_request(socket) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms

    with {:ok, <<length::unsigned-big-32>>} <- read_exact(socket, 4, deadline, []),
         true <- length in 1..@maximum_request_bytes,
         {:ok, payload} <- read_exact(socket, length, deadline, []) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp read_exact(_, 0, _, parts),
    do: {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact(socket, count, deadline, parts) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      case :socket.recv(socket, count, remaining_ms) do
        {:ok, bytes} when byte_size(bytes) > 0 ->
          read_exact(socket, count - byte_size(bytes), deadline, [bytes | parts])

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :closed}
      end
    end
  end

  defp decode_request(payload) do
    with {:ok, request} <-
           Wotex.JSON.decode(payload,
             max_bytes: @maximum_request_bytes,
             max_depth: 8,
             max_nodes: 128,
             max_string_bytes: 256,
             max_collection_size: 16
           ),
         %{"version" => 1, "requestId" => request_id, "operation" => operation} <- request,
         true <- is_binary(request_id) and byte_size(request_id) in 1..64,
         true <- operation in ~w(health metrics audit),
         true <-
           Enum.all?(Map.keys(request), &(&1 in ~w(version requestId operation cursor limit))),
         true <- valid_page(request) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp valid_page(%{"operation" => "health"} = request) do
    Map.keys(request) -- ~w(version requestId operation) == []
  end

  defp valid_page(request) do
    cursor = Map.get(request, "cursor")
    limit = Map.get(request, "limit", 50)

    (is_nil(cursor) or (is_integer(cursor) and cursor >= 0)) and
      is_integer(limit) and limit in 1..100
  end

  defp dispatch(%{"requestId" => request_id, "operation" => "health"}, library, metrics) do
    success_response(request_id, %{
      "store" => Library.diagnostics_health(library),
      "collector" => collector_status(metrics),
      "fallbackLog" => FallbackLog.status(),
      "observedAtMs" => System.os_time(:millisecond)
    })
  end

  defp dispatch(
         %{"requestId" => request_id, "operation" => operation} = request,
         library,
         metrics
       ) do
    cursor = Map.get(request, "cursor")
    limit = Map.get(request, "limit", 50)

    result =
      case operation do
        "metrics" -> Library.metric_page(library, cursor, limit)
        "audit" -> Library.audit_page(library, cursor, limit)
      end

    case result do
      {:error, code} ->
        error_response(request_id, code)

      page ->
        diagnostics =
          if operation == "metrics",
            do:
              page
              |> Map.put("coverage", collector_status(metrics))
              |> Map.put("catalog", Catalog.describe()),
            else: page

        success_response(request_id, diagnostics)
    end
  end

  defp collector_status(metrics) do
    observed_at_ms = System.os_time(:millisecond)

    try do
      status = Metrics.status(metrics)

      status
      |> Map.put("available", true)
      |> Map.put("observedAtMs", observed_at_ms)
      |> Map.put("resetAtMs", status["startedAtMs"])
      |> Map.put(
        "lossFreeSinceMs",
        if(status["droppedEvents"] == 0 and status["flushFailures"] == 0,
          do: status["startedAtMs"],
          else: nil
        )
      )
    catch
      :exit, _ ->
        %{
          "available" => false,
          "observedAtMs" => observed_at_ms,
          "resetAtMs" => nil,
          "lossFreeSinceMs" => nil
        }
    end
  end

  defp success_response(request_id, data) do
    %{"version" => 1, "requestId" => request_id, "ok" => true, "diagnostics" => data}
  end

  defp error_response(request_id, code) do
    %{
      "version" => 1,
      "requestId" => request_id,
      "ok" => false,
      "error" => %{"code" => Atom.to_string(code)}
    }
  end
end
