defmodule Frameshift.LocalIPC.Server do
  @moduledoc """
  Hosts authenticated finite shell commands on the native Unix socket.

  `start_link/1` requires a private path and validated per-launch token, with
  explicit or application-owned library/task/pairing dependencies. Each connection
  carries one four-byte-length-prefixed JSON request/response; the request ceiling
  is 64 KiB, the response ceiling 1 MiB and the request deadline five seconds.
  At most sixteen live connection workers are admitted; overflow closes before
  decode or command claim. Actual worker exit releases a slot, without a pending
  user-space queue or an automatic retry. There is no TCP listener.

  ## Command custody

  The request authenticates with the launch challenge before dispatch. Mutating
  commands carry stable bounded IDs and canonical payload digests; completed
  receipts suppress duplicate effects, changed payloads conflict and unresolved
  crash-window outcomes require reconciliation. The server never invents a new
  ID to conceal an uncertain mutation.

  `Frameshift.LocalAPI` owns ordinary product actions; physical pairing has its
  separate transient boundary. `libraryMetadata` and `libraryRecovery` are bounded
  authenticated reads, with digest identities and exclusive recovery cursors;
  they accept neither paths nor replacement provenance/capability documents.
  `libraryStorage` reports path-free registered-byte accounting and configuration
  identity; budget changes retain the ordinary durable command receipt boundary.
  `libraryAnalysis` verifies one bounded archive and `libraryAnalysisPending`
  lists at most sixteen active IDs for an exact native cohort. Neither operation
  changes state; chunked observation commands keep the existing JSON limits.
  `librarySimilarityCandidates` checks exact source feature identity and bounded
  facets on each digest-cursor page; Swift owns secure decoding and ranking.
  The listener monitors its acceptor and removes the
  socket on termination. The token file is consumed before startup through
  `Frameshift.LocalIPC.Token`; read-only diagnostics use a separate peer-UID
  endpoint and cannot inherit this mutation dispatcher.
  """

  use GenServer

  require Logger

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalAPI
  alias Frameshift.LocalIPC.SocketDirectory
  alias Frameshift.Outbox.Service
  alias Frameshift.Pairing.Admission
  alias Frameshift.RenderPreview

  @maximum_request_bytes 64 * 1024
  @maximum_response_bytes 1024 * 1024
  @request_timeout_ms 5_000
  @maximum_clients 16
  @token_pattern ~r/^[0-9a-f]{64}$/
  @request_keys %{
    "command" => ~w(version requestId operation auth command),
    "snapshot" => ~w(version requestId operation auth query filters),
    "preview" => ~w(version requestId operation auth itemID targetID profileID capabilityDigest),
    "libraryMetadata" => ~w(version requestId operation auth itemID),
    "libraryRecovery" => ~w(version requestId operation auth afterID),
    "libraryAnalysis" => ~w(version requestId operation auth itemID),
    "libraryAnalysisPending" => ~w(version requestId operation auth cohort),
    "librarySimilarityCandidates" =>
      ~w(version requestId operation auth itemID cohort featureDigest afterID filters),
    "pair" => ~w(version requestId operation auth bootstrap discoveredId origin credentialRef),
    "recoverPair" =>
      ~w(version requestId operation auth bootstrap discoveredId origin credentialRef)
  }

  defmodule State do
    @moduledoc """
    Tracks the command listener and acceptor for one native core process.

    The required listener, acceptor and private path remain owned by
    `Frameshift.LocalIPC.Server`. Acceptor termination stops the server; owner
    termination closes the listener and removes the endpoint, avoiding an orphaned
    command socket with ambiguous launch authority.

    ## Custody boundary

    This value is transient process state, not a command receipt or token store.
    Completed/pending commands retain their durable library records independently.
    External clients address the socket protocol and must not receive listener
    handles or construct a replacement state to bypass startup admission.
    """

    @type t :: %__MODULE__{acceptor: term(), listener: term(), path: String.t()}

    @enforce_keys [:acceptor, :listener, :path]
    defstruct [:acceptor, :listener, :path]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl true
  def init(options) do
    path = options |> Keyword.fetch!(:path) |> Path.expand()
    token = Keyword.fetch!(options, :token)
    library = Keyword.get(options, :library, Frameshift.Library)
    task_supervisor = Keyword.get(options, :task_supervisor, Frameshift.TaskSupervisor)
    pairing = Keyword.get(options, :pairing, Application.get_env(:frameshift_core, :pairing, []))

    with :ok <- validate_token(token),
         :ok <- prepare_path(path),
         {:ok, listener} <- listen(path),
         :ok <- File.chmod(path, 0o600),
         {:ok, acceptor} <- start_acceptor(task_supervisor, listener, library, token, pairing) do
      Process.monitor(acceptor)
      {:ok, %State{acceptor: acceptor, listener: listener, path: path}}
    else
      {:error, reason} -> {:stop, reason}
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
    :gen_tcp.close(listener)
    File.rm(path)
    :ok
  end

  defp prepare_path(path) do
    with :ok <- SocketDirectory.prepare(path) do
      remove_stale_socket(path)
    end
  end

  defp remove_stale_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :other}} ->
        case :gen_tcp.connect({:local, path}, 0, socket_options(), 250) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            {:error, :socket_already_active}

          {:error, :econnrefused} ->
            File.rm(path)

          {:error, :enoent} ->
            :ok

          {:error, _} ->
            {:error, :socket_path_busy}
        end

      {:ok, %File.Stat{}} ->
        {:error, :unsafe_socket_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp listen(path) do
    :gen_tcp.listen(0, [
      :binary,
      {:packet, 4},
      {:packet_size, @maximum_request_bytes},
      {:active, false},
      {:backlog, 16},
      {:ifaddr, {:local, path}}
    ])
  end

  defp start_acceptor(task_supervisor, listener, library, token, pairing) do
    Task.Supervisor.start_child(task_supervisor, fn ->
      accept_loop(task_supervisor, listener, library, token, pairing, [])
    end)
  end

  defp accept_loop(task_supervisor, listener, library, token, pairing, workers) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        live_workers = Enum.filter(workers, &Process.alive?/1)
        next_workers = hand_off(task_supervisor, socket, library, token, pairing, live_workers)
        accept_loop(task_supervisor, listener, library, token, pairing, next_workers)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp hand_off(_, socket, _, _, _, workers) when length(workers) >= @maximum_clients do
    :gen_tcp.close(socket)
    workers
  end

  defp hand_off(task_supervisor, socket, library, token, pairing, workers) do
    case Task.Supervisor.start_child(task_supervisor, fn ->
           receive do
             {:serve, ^socket} -> serve(socket, library, token, pairing)
           after
             @request_timeout_ms -> :gen_tcp.close(socket)
           end
         end) do
      {:ok, worker} ->
        case :gen_tcp.controlling_process(socket, worker) do
          :ok ->
            send(worker, {:serve, socket})
            [worker | workers]

          {:error, _} ->
            :gen_tcp.close(socket)
            # This worker still owns its finite handoff wait until it exits.
            [worker | workers]
        end

      {:error, _} ->
        :gen_tcp.close(socket)
        workers
    end
  end

  defp serve(socket, library, token, pairing) do
    response =
      case :gen_tcp.recv(socket, 0, @request_timeout_ms) do
        {:ok, payload} -> dispatch(payload, library, token, pairing)
        {:error, :timeout} -> error_response(nil, :request_timeout)
        {:error, _} -> error_response(nil, :invalid_request)
      end

    with {:ok, encoded} <- RFC8785.encode(response),
         true <- byte_size(encoded) <= @maximum_response_bytes do
      :gen_tcp.send(socket, encoded)
    else
      _ ->
        :gen_tcp.send(socket, ~s({"ok":false,"version":1,"error":{"code":"internal_error"}}))
    end

    :gen_tcp.close(socket)
  catch
    kind, _ ->
      Logger.error("local IPC request failed", frameshift_event: :ipc_failure, error_class: kind)
      :gen_tcp.close(socket)
  end

  defp dispatch(payload, library, token, pairing) do
    with {:ok, request} <- decode_request(payload),
         :ok <- authenticate(request, token),
         {:ok, response} <- execute_request(request, library, pairing) do
      response
    else
      {:error, {request_id, code}} -> error_response(request_id, code)
      {:error, code} -> error_response(nil, code)
    end
  end

  defp decode_request(payload) do
    case Wotex.JSON.decode(payload,
           max_bytes: @maximum_request_bytes,
           max_depth: 16,
           max_nodes: 2_048,
           max_string_bytes: 8_192,
           max_collection_size: 256
         ) do
      {:ok, request} when is_map(request) -> validate_request(request)
      {:ok, _} -> {:error, :invalid_request}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp validate_request(
         %{
           "version" => 1,
           "requestId" => request_id,
           "operation" => operation,
           "auth" => auth
         } = request
       ) do
    allowed = Map.get(@request_keys, operation, ~w(version requestId operation auth))

    with :ok <- validate_request_id(request_id),
         :ok <- validate_operation(operation),
         :ok <- validate_auth_shape(auth),
         :ok <- validate_request_keys(request, allowed, request_id),
         :ok <- validate_command_shape(request, operation, request_id),
         :ok <- validate_query_shape(request, operation, request_id),
         :ok <- validate_preview_shape(request, operation, request_id),
         :ok <- validate_library_read(request, operation, request_id),
         :ok <- validate_pairing_shape(request, operation, request_id) do
      {:ok, request}
    end
  end

  defp validate_request(request) when is_map(request) do
    request_id = Map.get(request, "requestId")
    safe_id = if is_binary(request_id) and byte_size(request_id) in 1..64, do: request_id
    {:error, {safe_id, :invalid_request}}
  end

  defp validate_request_id(request_id)
       when is_binary(request_id) and byte_size(request_id) in 1..64,
       do: :ok

  defp validate_request_id(request_id),
    do: {:error, {safe_request_id(request_id), :invalid_request}}

  defp validate_operation(operation)
       when operation in [
              "snapshot",
              "preview",
              "libraryMetadata",
              "libraryRecovery",
              "libraryStorage",
              "libraryAnalysis",
              "libraryAnalysisPending",
              "librarySimilarityCandidates",
              "command",
              "pair",
              "recoverPair",
              "outboxStatus"
            ],
       do: :ok

  defp validate_operation(_), do: {:error, :invalid_request}

  defp validate_auth_shape(auth) when is_binary(auth) and byte_size(auth) == 64, do: :ok
  defp validate_auth_shape(_), do: {:error, :invalid_request}

  defp validate_request_keys(request, allowed, request_id) do
    if Enum.any?(Map.keys(request), &(&1 not in allowed)),
      do: {:error, {request_id, :invalid_request}},
      else: :ok
  end

  defp validate_command_shape(request, "command", request_id) do
    case Map.get(request, "command") do
      %{"id" => command_id} when is_binary(command_id) and byte_size(command_id) in 1..64 ->
        :ok

      _ ->
        {:error, {request_id, :invalid_command}}
    end
  end

  defp validate_command_shape(_, _, _), do: :ok

  defp validate_query_shape(request, "snapshot", request_id) do
    case Map.get(request, "query", "") do
      query when is_binary(query) and byte_size(query) <= 256 ->
        case LocalAPI.validate_filters(Map.get(request, "filters", %{})) do
          :ok -> :ok
          _ -> {:error, {request_id, :invalid_request}}
        end

      _ ->
        {:error, {request_id, :invalid_request}}
    end
  end

  defp validate_query_shape(_, _, _), do: :ok

  defp validate_preview_shape(request, "preview", request_id) do
    target = Map.get(request, "targetID")
    profile = Map.get(request, "profileID")
    digest = Map.get(request, "capabilityDigest")

    if Digest.valid_sha256?(request["itemID"]) and preview_target?(target, profile, digest),
      do: :ok,
      else: {:error, {request_id, :invalid_request}}
  end

  defp validate_preview_shape(_, _, _), do: :ok

  defp validate_library_read(request, operation, request_id)
       when operation in ["libraryMetadata", "libraryAnalysis"] do
    if Digest.valid_sha256?(request["itemID"]),
      do: :ok,
      else: {:error, {request_id, :invalid_request}}
  end

  defp validate_library_read(request, "libraryRecovery", request_id) do
    if request["afterID"] == nil or Digest.valid_sha256?(request["afterID"]),
      do: :ok,
      else: {:error, {request_id, :invalid_request}}
  end

  defp validate_library_read(request, "libraryAnalysisPending", request_id) do
    if Frameshift.Library.Metadata.vision_cohort?(request["cohort"]),
      do: :ok,
      else: {:error, {request_id, :invalid_request}}
  end

  defp validate_library_read(request, "librarySimilarityCandidates", request_id) do
    with true <- Digest.valid_sha256?(request["itemID"]),
         true <- Digest.valid_sha256?(request["featureDigest"]),
         true <- Frameshift.Library.Metadata.vision_cohort?(request["cohort"]),
         true <- request["afterID"] == nil or Digest.valid_sha256?(request["afterID"]),
         :ok <- LocalAPI.validate_filters(request["filters"]) do
      :ok
    else
      _ -> {:error, {request_id, :invalid_request}}
    end
  end

  defp validate_library_read(_, _, _), do: :ok

  defp preview_target?(nil, nil, nil), do: true

  defp preview_target?(target, profile, digest)
       when is_binary(target) and byte_size(target) in 1..128 and
              is_binary(profile) and byte_size(profile) in 1..128,
       do: Digest.valid_sha256?(digest)

  defp preview_target?(_, _, _), do: false

  defp validate_pairing_shape(request, operation, request_id)
       when operation in ["pair", "recoverPair"] do
    with bootstrap when is_binary(bootstrap) and byte_size(bootstrap) in 1..2_048 <-
           Map.get(request, "bootstrap"),
         discovered_id when is_binary(discovered_id) and byte_size(discovered_id) in 16..128 <-
           Map.get(request, "discoveredId"),
         origin when is_binary(origin) and byte_size(origin) in 1..1_024 <-
           Map.get(request, "origin"),
         reference when is_binary(reference) and byte_size(reference) in 1..1_024 <-
           Map.get(request, "credentialRef") do
      :ok
    else
      _ -> {:error, {request_id, :invalid_request}}
    end
  end

  defp validate_pairing_shape(_, _, _), do: :ok

  defp safe_request_id(request_id)
       when is_binary(request_id) and byte_size(request_id) in 1..64,
       do: request_id

  defp safe_request_id(_), do: nil

  defp validate_token(token) when is_binary(token) do
    if Regex.match?(@token_pattern, token), do: :ok, else: {:error, :invalid_ipc_token}
  end

  defp validate_token(_), do: {:error, :invalid_ipc_token}

  defp authenticate(%{"requestId" => request_id, "auth" => candidate}, token) do
    if secure_equal?(candidate, token),
      do: :ok,
      else: {:error, {request_id, :authentication_required}}
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, difference ->
      Bitwise.bor(difference, Bitwise.bxor(left_byte, right_byte))
    end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_, _), do: false

  defp execute_request(
         %{"requestId" => request_id, "operation" => "snapshot"} = request,
         library,
         _
       ) do
    case LocalAPI.filtered_snapshot(
           library,
           Map.get(request, "query", ""),
           Map.get(request, "filters", %{})
         ) do
      {:ok, snapshot} -> {:ok, success_response(request_id, snapshot)}
      {:error, code} -> {:error, {request_id, code}}
    end
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "preview", "itemID" => item_id} = request,
         library,
         _
       ) do
    target =
      if request["targetID"], do: Map.take(request, ~w(targetID profileID capabilityDigest))

    case RenderPreview.render(library, Frameshift.Renderer, item_id, target) do
      {:ok, preview} ->
        {:ok, %{"version" => 1, "requestId" => request_id, "ok" => true, "preview" => preview}}

      {:error, code} ->
        {:error, {request_id, code}}
    end
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "libraryMetadata", "itemID" => item_id},
         library,
         _
       ) do
    library_read_response(request_id, "metadata", Library.metadata(library, item_id))
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "libraryRecovery"} = request,
         library,
         _
       ) do
    library_read_response(
      request_id,
      "recovery",
      Library.recovery_page(library, request["afterID"])
    )
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "outboxStatus"},
         _,
         _
       ) do
    status =
      if Process.whereis(Service) do
        Service.status()
      else
        %{available: false, port: nil}
      end

    {:ok,
     %{
       "version" => 1,
       "requestId" => request_id,
       "ok" => true,
       "outbox" => %{"available" => status.available, "port" => status.port}
     }}
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "libraryStorage"},
         library,
         _
       ) do
    library_read_response(request_id, "storage", Library.storage(library))
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "libraryAnalysis", "itemID" => item_id},
         library,
         _
       ) do
    library_read_response(request_id, "analysis", Library.analysis(library, item_id))
  end

  defp execute_request(
         %{
           "requestId" => request_id,
           "operation" => "libraryAnalysisPending",
           "cohort" => cohort
         },
         library,
         _
       ) do
    library_read_response(
      request_id,
      "analysisPending",
      Library.analysis_pending(library, cohort)
    )
  end

  defp execute_request(
         %{
           "requestId" => request_id,
           "operation" => "recoverPair",
           "bootstrap" => bootstrap,
           "discoveredId" => discovered_id,
           "origin" => origin,
           "credentialRef" => reference
         },
         library,
         pairing
       ) do
    options = Keyword.put(pairing, :library, library)

    case Admission.recover(bootstrap, discovered_id, origin, reference, options) do
      {:ok, frame} ->
        {:ok, %{"version" => 1, "requestId" => request_id, "ok" => true, "frame" => frame}}

      {:error, code} ->
        {:error, {request_id, code}}
    end
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "command", "command" => command},
         library,
         _
       ) do
    started = System.monotonic_time(:millisecond)
    Logger.metadata(request_id: request_id, command_id: command["id"])

    result =
      with {:ok, command_hash} <- command_hash(command),
           {:ok, disposition} <- Library.claim_command(library, command["id"], command_hash) do
        execute_command(disposition, request_id, command, command_hash, library)
      else
        {:error, code} -> {:error, {request_id, code}}
      end

    outcome =
      case result do
        {:ok, _} -> :succeeded
        {:error, {_, :command_outcome_unknown}} -> :unknown
        {:error, _} -> :failed
      end

    duration_ms = System.monotonic_time(:millisecond) - started

    :telemetry.execute(
      [:frameshift, :command, :completed],
      %{count: 1, duration_ms: duration_ms},
      %{outcome: outcome}
    )

    Logger.info("local command completed",
      frameshift_event: :command_completed,
      frameshift_outcome: outcome,
      duration_ms: duration_ms
    )

    result
  end

  defp execute_request(
         %{
           "requestId" => request_id,
           "operation" => "pair",
           "bootstrap" => bootstrap,
           "discoveredId" => discovered_id,
           "origin" => origin,
           "credentialRef" => reference
         },
         library,
         pairing
       ) do
    options = Keyword.put(pairing, :library, library)

    case Admission.pair(bootstrap, discovered_id, origin, reference, request_id, options) do
      {:ok, frame} ->
        {:ok, %{"version" => 1, "requestId" => request_id, "ok" => true, "frame" => frame}}

      {:error, code} ->
        {:error, {request_id, code}}
    end
  end

  defp execute_request(
         %{"requestId" => request_id, "operation" => "librarySimilarityCandidates"} = request,
         library,
         _
       ) do
    library_read_response(
      request_id,
      "similarityCandidates",
      Library.similarity_candidates(library, request)
    )
  end

  defp library_read_response(request_id, key, {:ok, value}),
    do: {:ok, %{"version" => 1, "requestId" => request_id, "ok" => true, key => value}}

  defp library_read_response(request_id, _, {:error, code}), do: {:error, {request_id, code}}

  defp execute_command(:execute, request_id, command, command_hash, library) do
    outcome = LocalAPI.execute(library, command)

    receipt_outcome =
      case outcome do
        {:ok, _} -> :ok
        {:error, code} -> {:error, code}
      end

    case Library.complete_command(library, command["id"], command_hash, receipt_outcome) do
      :ok -> command_response(request_id, outcome)
      {:error, _} -> {:error, {request_id, :command_outcome_unknown}}
    end
  end

  defp execute_command({:replay, :ok}, request_id, _, _, library) do
    {:ok, success_response(request_id, LocalAPI.snapshot(library, "Command already applied"))}
  end

  defp execute_command(
         {:replay, {:error, error_code}},
         request_id,
         _,
         _,
         _
       ) do
    {:error, {request_id, error_code}}
  end

  defp execute_command(:pending, request_id, _, _, _),
    do: {:error, {request_id, :command_outcome_unknown}}

  defp command_response(request_id, {:ok, snapshot}),
    do: {:ok, success_response(request_id, snapshot)}

  defp command_response(request_id, {:error, code}), do: {:error, {request_id, code}}

  defp command_hash(command) do
    canonical_result =
      command
      |> Map.delete("importCanonicalPath")
      |> RFC8785.encode()

    case canonical_result do
      {:ok, canonical} -> {:ok, Digest.sha256(canonical)}
      {:error, _} -> {:error, :invalid_command}
    end
  end

  defp success_response(request_id, snapshot) do
    %{"version" => 1, "requestId" => request_id, "ok" => true, "snapshot" => snapshot}
  end

  defp error_response(request_id, code) do
    encoded_code = if is_atom(code), do: Atom.to_string(code), else: code

    %{
      "version" => 1,
      "requestId" => request_id,
      "ok" => false,
      "error" => %{"code" => encoded_code}
    }
  end

  defp socket_options do
    [:binary, {:packet, 4}, {:packet_size, @maximum_request_bytes}, {:active, false}]
  end
end
