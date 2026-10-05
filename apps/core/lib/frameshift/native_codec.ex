defmodule Frameshift.NativeCodec do
  @moduledoc """
  Owns one bounded original-byte normalization job against a staged codec build.

  Start with an explicit executable `:path` and an existing private temporary
  directory selected by `System.tmp_dir!/0`. The directory must be a real 0700
  inode owned by the actual nonroot file-creation identity. This also protects
  Exile's transient descriptor handshake. Startup copies at most 64 MiB of
  protected executable bytes into an exclusive custody directory, verifies readback and
  records their digest; replacing the configured path cannot change this owner.

  ## Qualification and lifetime

  `normalize/4` requires the expected executable digest and exact source bytes.
  One supervised task checks the producer revision, closes stdin after the
  bounded request, validates FSN1 output before reading pixels and awaits native
  exit before returning a result. The codec runs through the fixed system `env`
  executable with an empty environment and disabled stderr. Source paths,
  credentials and caller-declared pixels do not enter the worker.

  A deadline returns `:codec_timeout` and requests native termination. The slot
  remains occupied until cleanup returns an actual exit acknowledgement; a new
  request cannot replace work merely because its caller stopped waiting. Lost
  native custody leaves this owner unavailable. No job, provider or library
  effect is automatically retried. Returned metadata includes both producer
  revision and the executed binary digest for immutable master provenance.

  An independent watchdog retains the absolute deadline and monitors the owner.
  The custody directory is retained after an abrupt owner death or unknown exit;
  a replacement owner refuses to overwrite it. Remove abandoned custody only
  after stopping the complete installed service and verifying native termination.
  This process lease does not establish crash-durable storage or a sandbox.

  This module creates no masters and exposes no Unix endpoint. Authenticated
  upload, actor-bound receipts and Library admission remain separate owners.
  Installed process/resource limits, abrupt VM termination and target NIF/helper
  closure require Linux release evidence beyond a successful local decode.
  """

  use GenServer

  import Bitwise

  alias Frameshift.Digest
  alias Frameshift.NativeCodec.LogPrivacy
  alias Frameshift.NativeCodec.Protocol

  @revision "frameshift-codec/1 png/0.18.1 jpeg/0.3.2-fs.1 moxcms/0.9.1 exif/0.6.1 scalar-sdr/1"
  @maximum_executable_bytes 64 * 1024 * 1024
  @default_deadline 30_000
  @chunk_bytes 65_536
  @exit_timeout 1_000

  @type server :: GenServer.server()

  @doc "Starts a private owner for one snapshotted codec executable."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Returns the executable digest captured for this worker owner."
  @spec build_digest(server()) :: String.t()
  def build_digest(server \\ __MODULE__), do: GenServer.call(server, :build_digest)

  @doc "Returns the exact producer revision required before source bytes are sent."
  @spec revision() :: String.t()
  def revision, do: @revision

  @doc "Normalizes exact source bytes only under the caller's admitted executable digest."
  @spec normalize(server(), binary(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def normalize(server, source, expected_digest, options \\ []) do
    deadline = Keyword.get(options, :deadline_ms, @default_deadline)

    GenServer.call(
      server,
      {:normalize, source, expected_digest, deadline},
      @default_deadline + 5_000
    )
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    with :ok <- LogPrivacy.install(),
         :ok <- validate_env(),
         true <- is_binary(Keyword.get(options, :path)),
         {:ok, directory} <- prepare_directory(),
         {:ok, path, digest} <- snapshot(Keyword.fetch!(options, :path), directory),
         true <- Digest.valid_sha256?(digest) do
      {:ok,
       %{
         path: path,
         directory: directory,
         digest: digest,
         tasks: Keyword.get(options, :task_supervisor, Frameshift.TaskSupervisor),
         pending: nil,
         unavailable: false
       }}
    else
      false -> {:stop, :unsafe_codec_executable}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:build_digest, _, state), do: {:reply, state.digest, state}

  def handle_call({:normalize, _, _, _}, _, %{unavailable: true} = state),
    do: {:reply, {:error, :codec_custody_unknown}, state}

  def handle_call({:normalize, _, _, _}, _, %{pending: pending} = state) when pending != nil,
    do: {:reply, {:error, :codec_busy}, state}

  def handle_call({:normalize, source, expected, deadline}, from, state) do
    with true <- expected == state.digest,
         true <- is_integer(deadline) and deadline in 1..@default_deadline,
         {:ok, _} <- Protocol.encode_request(source) do
      owner = self()
      reference = make_ref()

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          run(owner, reference, state.path, source, deadline)
        end)

      timer = Process.send_after(self(), {:deadline, reference}, deadline)

      {:noreply,
       %{
         state
         | pending: %{
             task: task,
             reference: reference,
             timer: timer,
             from: from,
             process: nil,
             operation: nil,
             watchdog: nil,
             timed_out: false
           }
       }}
    else
      false ->
        {:reply,
         {:error,
          if(expected != state.digest, do: :codec_build_mismatch, else: :invalid_codec_deadline)},
         state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    _ -> {:reply, {:error, :codec_worker_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :codec_worker_unavailable}, state}
  end

  @impl true
  def handle_info(
        {:native_process, reference, process, operation},
        %{pending: %{reference: reference} = pending} = state
      ) do
    {:noreply, %{state | pending: %{pending | process: process, operation: operation}}}
  end

  def handle_info(
        {:native_watchdog, reference, watchdog},
        %{pending: %{reference: reference} = pending} = state
      ) do
    if pending.timed_out, do: send(watchdog, :cancel)
    {:noreply, %{state | pending: %{pending | watchdog: watchdog}}}
  end

  def handle_info({:deadline, reference}, %{pending: %{reference: reference} = pending} = state) do
    reply(pending, {:error, :codec_timeout})
    send(pending.task.pid, {:codec_cancel, reference})
    if pending.watchdog, do: send(pending.watchdog, :cancel)
    {:noreply, %{state | pending: %{pending | from: nil, timed_out: true}}}
  end

  def handle_info(
        {reference, {result, custody}},
        %{pending: %{task: %{ref: reference}} = pending} = state
      ) do
    Process.demonitor(reference, [:flush])
    Process.cancel_timer(pending.timer)
    result = enrich(result, state.digest)
    reply(pending, result)
    {:noreply, %{state | pending: nil, unavailable: custody != :exited}}
  end

  def handle_info(
        {:DOWN, reference, :process, _, _},
        %{pending: %{task: %{ref: reference}} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    if pending.watchdog, do: send(pending.watchdog, :cancel)
    reply(pending, {:error, :codec_custody_unknown})
    {:noreply, %{state | pending: nil, unavailable: true}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{pending: nil, unavailable: false, directory: directory}),
    do: cleanup(directory)

  def terminate(_, %{pending: nil}), do: :ok

  def terminate(_, %{pending: pending, directory: directory}) do
    send(pending.task.pid, {:codec_cancel, pending.reference})
    if pending.watchdog, do: send(pending.watchdog, :cancel)

    case Task.yield(pending.task, @exit_timeout + 500) do
      {:ok, {_, :exited}} -> cleanup(directory)
      _ -> Task.shutdown(pending.task, :brutal_kill)
    end

    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [:redacted])
    |> Map.update(:state, %{}, fn state ->
      state
      |> Map.put(:path, "<redacted>")
      |> Map.put(:directory, "<redacted>")
      |> Map.put(:pending, if(state.pending, do: :redacted, else: nil))
    end)
  end

  defp run(owner, reference, path, source, deadline) do
    Process.flag(:trap_exit, true)
    worker = self()
    watchdog = spawn(fn -> watch(owner, worker, reference, deadline) end)
    send(owner, {:native_watchdog, reference, watchdog})

    try do
      case invoke(owner, watchdog, reference, path, ["--version"], nil, :revision) do
        {{:ok, _}, :exited} ->
          receive do
            {:codec_cancel, ^reference} -> {{:error, :codec_timeout}, :exited}
          after
            0 -> invoke(owner, watchdog, reference, path, [], source, :decode)
          end

        result ->
          result
      end
    after
      send(watchdog, :finished)
    end
  rescue
    _ -> {{:error, :codec_worker_unavailable}, :unknown}
  catch
    _, _ -> {{:error, :codec_worker_unavailable}, :unknown}
  end

  defp invoke(owner, watchdog, reference, path, arguments, source, operation) do
    :ok = private_temporary_directory()

    {:ok, process} =
      Exile.Process.start_link(["/usr/bin/env", "-i", path | arguments],
        cd: Path.dirname(path),
        stderr: :disable
      )

    send(owner, {:native_process, reference, process, operation})
    send(watchdog, {:native_process, process})
    result = exchange(process, source, operation)

    case await_native(process) do
      {:ok, 0} -> {result, :exited}
      {:ok, _} -> {{:error, :codec_worker_exit}, :exited}
      _ -> {{:error, :codec_custody_unknown}, :unknown}
    end
  end

  defp watch(owner, worker, reference, deadline) do
    owner_monitor = Process.monitor(owner)
    worker_monitor = Process.monitor(worker)
    Process.send_after(self(), :deadline, deadline)
    watch(worker, reference, owner_monitor, worker_monitor, nil, false)
  end

  defp watch(worker, reference, owner_monitor, worker_monitor, native, cancelled) do
    receive do
      {:native_process, process} ->
        if cancelled, do: stop_native(process)
        watch(worker, reference, owner_monitor, worker_monitor, process, cancelled)

      {:DOWN, ^owner_monitor, :process, _, _} ->
        send(worker, {:codec_cancel, reference})
        if native, do: stop_native(native)
        watch(worker, reference, owner_monitor, worker_monitor, native, true)

      cancellation when cancellation in [:deadline, :cancel] ->
        send(worker, {:codec_cancel, reference})
        if native, do: stop_native(native)
        watch(worker, reference, owner_monitor, worker_monitor, native, true)

      {:DOWN, ^worker_monitor, :process, _, _} ->
        if native, do: stop_native(native)

      :finished ->
        :ok
    end
  end

  defp exchange(process, source, operation) do
    with :ok <- LogPrivacy.mark(process),
         :ok <- write_source(process, source),
         :ok <- Exile.Process.close_stdin(process) do
      read_result(process, operation)
    else
      _ -> {:error, :codec_io}
    end
  rescue
    _ -> {:error, :codec_io}
  catch
    _, _ -> {:error, :codec_io}
  end

  defp write_source(_, nil), do: :ok

  defp write_source(process, source) do
    with :ok <- Exile.Process.write(process, <<byte_size(source)::unsigned-big-32>>),
         do: write_chunks(process, source)
  end

  defp write_chunks(_, <<>>), do: :ok

  defp write_chunks(process, source) do
    count = min(byte_size(source), @chunk_bytes)
    <<chunk::binary-size(^count), rest::binary>> = source
    with :ok <- Exile.Process.write(process, chunk), do: write_chunks(process, rest)
  end

  defp read_result(process, :revision) do
    expected = @revision <> "\n"

    with {:ok, ^expected} <- read_exact(process, byte_size(expected)),
         :eof <- Exile.Process.read(process, 1) do
      {:ok, :revision_verified}
    else
      _ -> {:error, :codec_revision_mismatch}
    end
  end

  defp read_result(process, :decode) do
    with {:ok, bytes} <- read_exact(process, Protocol.header_bytes()),
         {:ok, header} <- Protocol.decode_header(bytes),
         {:ok, rgba} <- read_exact(process, header.rgba_bytes),
         :eof <- Exile.Process.read(process, 1) do
      Protocol.decode_response(bytes, rgba)
    else
      {:worker_error, reason} ->
        if Exile.Process.read(process, 1) == :eof,
          do: {:error, reason},
          else: {:error, :invalid_codec_header}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_codec_pixels}
    end
  end

  defp read_exact(process, count), do: read_exact(process, count, [])
  defp read_exact(_, 0, chunks), do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact(process, remaining, chunks) do
    case Exile.Process.read(process, min(remaining, @chunk_bytes)) do
      {:ok, data} when is_binary(data) and byte_size(data) in 1..remaining//1 ->
        read_exact(process, remaining - byte_size(data), [data | chunks])

      _ ->
        {:error, :codec_io}
    end
  end

  defp await_native(process) do
    Exile.Process.await_exit(process, @exit_timeout)
  catch
    _, _ -> :unknown
  end

  defp stop_native(process) do
    Exile.Process.kill(process, :sigkill)
  catch
    _, _ -> :unknown
  end

  defp reply(%{from: nil}, _), do: :ok
  defp reply(%{from: from}, result), do: GenServer.reply(from, result)

  defp enrich({:ok, result}, digest),
    do: {:ok, Map.merge(result, %{codec_digest: digest, codec_revision: @revision})}

  defp enrich(error, _), do: error

  defp prepare_directory do
    root = System.tmp_dir!()
    directory = Path.join(root, "frameshift-codec-custody")

    with :ok <- private_temporary_directory(),
         :ok <- File.mkdir(directory) do
      with {:ok, %{uid: uid}} <- File.lstat(root),
           :ok <- File.chmod(directory, 0o700),
           {:ok, %{uid: ^uid, type: :directory}} <- File.lstat(directory) do
        {:ok, directory}
      else
        _ ->
          cleanup(directory)
          {:error, :unsafe_codec_temporary_directory}
      end
    else
      {:error, :eexist} -> {:error, :codec_custody_exists}
      _ -> {:error, :unsafe_codec_temporary_directory}
    end
  end

  defp private_temporary_directory do
    case File.lstat(System.tmp_dir!()) do
      {:ok, %{type: :directory, uid: uid, mode: mode}}
      when uid > 0 and (mode &&& 0o7777) == 0o700 ->
        :ok

      _ ->
        {:error, :unsafe_codec_temporary_directory}
    end
  end

  defp snapshot(source, directory) do
    destination = Path.join(directory, "worker")
    {:ok, %{uid: uid}} = File.lstat(directory)

    with {:ok, bytes} <- read_executable(source, uid),
         :ok <- File.write(destination, bytes, [:exclusive]),
         :ok <- File.chmod(destination, 0o500),
         {:ok, ^bytes} <- File.read(destination) do
      {:ok, destination, Digest.sha256(bytes)}
    else
      _ ->
        cleanup(directory)
        {:error, :unsafe_codec_executable}
    end
  end

  defp read_executable(path, uid) do
    with {:ok, %{type: :regular, uid: owner, mode: mode, size: size} = before} <-
           File.lstat(path, time: :posix),
         true <-
           owner in [0, uid] and (mode &&& 0o022) == 0 and (mode &&& 0o111) != 0 and
             size in 1..@maximum_executable_bytes,
         {:ok, file} <- File.open(path, [:read, :raw, :binary]) do
      try do
        with {:ok, record} <- :file.read_file_info(file, time: :posix),
             true <- same_file?(File.Stat.from_record(record), before),
             {:ok, bytes} when byte_size(bytes) == size <-
               :file.read(file, @maximum_executable_bytes + 1),
             :eof <- :file.read(file, 1),
             {:ok, after_read} <- :file.read_file_info(file, time: :posix),
             {:ok, final} <- File.lstat(path, time: :posix),
             true <-
               same_file?(File.Stat.from_record(after_read), before) and same_file?(final, before) do
          {:ok, bytes}
        else
          _ -> {:error, :unsafe_codec_executable}
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :unsafe_codec_executable}
    end
  end

  defp same_file?(left, right), do: Map.delete(left, :atime) == Map.delete(right, :atime)

  defp validate_env do
    case File.lstat("/usr/bin/env") do
      {:ok, %{type: :regular, uid: 0, mode: mode}} when (mode &&& 0o022) == 0 -> :ok
      _ -> {:error, :codec_environment_unavailable}
    end
  end

  defp cleanup(directory) do
    File.rm_rf(directory)
    :ok
  end
end
