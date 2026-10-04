defmodule Frameshift.Renderer do
  @moduledoc """
  Supervises one bounded isolated Zig raster worker.

  Start with `start_link/1` and an explicit executable `:path`. The owner stages
  and fingerprints the executable, opens its port and accepts one render at a
  time; a concurrent request returns `:busy`. `Frameshift.Renderer.Protocol`
  checks jobs and incrementally validates framed responses before returning pixels.

  ## Deadlines and executable identity

  `render/3` accepts a `:deadline_ms` option, defaulting to 30 seconds.
  `render_qualified/4` also requires the expected executable digest, refusing a
  build mismatch before sending the job. `build_digest/1` reports the digest
  captured for this worker instance rather than a mutable path's current bytes.

  Timeout, worker exit or malformed framing stops the owner so supervision starts
  a clean worker. Pending calls fail; they are not automatically replayed into
  replacement process state. Job pixels and credentials do not belong in process
  diagnostics. `Frameshift.RenderPipeline` owns durable master/cache relationships;
  the worker owns only bounded raster computation and transient response state.
  """

  use GenServer

  alias Frameshift.Digest
  alias Frameshift.Renderer.Protocol

  @default_timeout_ms 30_000
  @maximum_response_bytes Protocol.maximum_frame_bytes()
  @maximum_executable_bytes 64 * 1024 * 1024

  defmodule State do
    @moduledoc """
    Tracks one staged renderer build and bounded in-flight response.

    The state owns the port, executable build digest/staging path, pending caller,
    expected response and accumulated prefix/chunks/byte count. Its counters enforce
    the worker-frame ceiling before a completed response is exposed.

    ## Replacement boundary

    `Frameshift.Renderer` creates the state during startup and discards it after
    worker loss, deadline or malformed framing. A subsequent process cannot inherit
    an ambiguous old response or numeric port identity. Process-status formatting
    redacts job/response material; durable recipes and artifacts belong to
    `Frameshift.Library`, not this transient worker value.
    """

    @type t :: %__MODULE__{
            port: port() | pid(),
            build_digest: String.t() | nil,
            staged_path: String.t() | nil,
            pending: term(),
            expected: term(),
            prefix: binary(),
            chunks: [binary()],
            received: non_neg_integer()
          }

    @enforce_keys [:port]
    defstruct [
      :port,
      :build_digest,
      :staged_path,
      :pending,
      :expected,
      prefix: <<>>,
      chunks: [],
      received: 0
    ]
  end

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @spec render(server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def render(server \\ __MODULE__, job, options \\ []) do
    timeout = Keyword.get(options, :deadline_ms, @default_timeout_ms)
    GenServer.call(server, {:render, job, timeout}, call_timeout(timeout))
  end

  @doc "Renders only when this worker owner fingerprints to the admitted executable build."
  @spec render_qualified(server(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def render_qualified(server, job, expected_digest, options \\ []) do
    timeout = Keyword.get(options, :deadline_ms, @default_timeout_ms)

    GenServer.call(
      server,
      {:render_qualified, job, timeout, expected_digest},
      call_timeout(timeout)
    )
  end

  @doc "Returns the SHA-256 digest of the executable read when this worker owner started."
  @spec build_digest(server()) :: String.t()
  def build_digest(server \\ __MODULE__), do: GenServer.call(server, :build_digest)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    path = options |> Keyword.fetch!(:path) |> Path.expand()

    with :ok <- validate_options(path),
         {:ok, port, staged_path, build_digest} <- open_staged_worker(path) do
      {:ok, %State{port: port, staged_path: staged_path, build_digest: build_digest}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:build_digest, _, state), do: {:reply, state.build_digest, state}

  def handle_call({:render, _, _}, _, %{pending: pending} = state)
      when pending != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:render_qualified, _, _, _}, _, %{pending: pending} = state)
      when pending != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:render_qualified, _, _, expected_digest}, _, state)
      when expected_digest != state.build_digest do
    {:reply, {:error, :renderer_build_mismatch}, state}
  end

  def handle_call({:render_qualified, job, timeout, _}, from, state) do
    start_render(job, timeout, from, state)
  end

  def handle_call({:render, job, timeout}, from, state) do
    start_render(job, timeout, from, state)
  end

  defp start_render(job, timeout, from, state) do
    with :ok <- validate_timeout(timeout),
         {:ok, request} <- Protocol.encode_request(job),
         :ok <- command_worker(state.port, request) do
      reference = make_ref()
      timer = Process.send_after(self(), {:render_timeout, reference}, timeout)
      pending = %{from: from, timer: timer, reference: reference}
      {:noreply, %{state | pending: pending}}
    else
      {:error, :worker_unavailable} ->
        {:stop, :worker_unavailable, {:error, :worker_unavailable}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    receive_data(state, data)
  end

  def handle_info({:render_timeout, reference}, %{pending: %{reference: reference}} = state) do
    GenServer.reply(state.pending.from, {:error, :timeout})
    {:stop, :render_timeout, clear_pending(state)}
  end

  def handle_info({:render_timeout, _}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reply_pending(state, {:error, {:worker_exit, status}})
    {:stop, {:worker_exit, status}, %{clear_pending(state) | port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    reply_pending(state, {:error, {:worker_exit, reason}})
    {:stop, {:worker_exit, reason}, %{clear_pending(state) | port: nil}}
  end

  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, fn
      %State{} = state ->
        %{state | prefix: "<redacted>", chunks: [:redacted], staged_path: "<redacted>"}

      _ ->
        :redacted
    end)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [:redacted])
  end

  @impl true
  def terminate(_, %{port: port} = state) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    cleanup_staged_path(state.staged_path)
    :ok
  end

  def terminate(_, state) do
    cleanup_staged_path(state.staged_path)
    :ok
  end

  defp receive_data(%{pending: nil} = state, _),
    do: fail_worker(state, :unexpected_response)

  defp receive_data(%{expected: nil} = state, data) do
    combined = state.prefix <> data

    if byte_size(combined) < 4 do
      {:noreply, %{state | prefix: combined}}
    else
      <<expected::unsigned-big-32, first_chunk::binary>> = combined
      begin_response(state, expected, first_chunk)
    end
  end

  defp receive_data(state, data) do
    continue_response(state, data)
  end

  defp begin_response(state, expected, _)
       when expected > @maximum_response_bytes,
       do: fail_worker(state, :response_too_large)

  defp begin_response(state, expected, first_chunk) do
    next_state = %{state | expected: expected, prefix: <<>>, chunks: [], received: 0}
    continue_response(next_state, first_chunk)
  end

  defp continue_response(state, chunk) do
    received = state.received + byte_size(chunk)

    cond do
      received > state.expected ->
        fail_worker(state, :multiple_responses)

      received < state.expected ->
        {:noreply, %{state | chunks: [chunk | state.chunks], received: received}}

      true ->
        body = state.chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary()
        finish_response(state, body)
    end
  end

  defp finish_response(state, body) do
    case Protocol.decode_response(body) do
      {:ok, result} -> reply_result(state, result)
      {:error, reason} -> fail_worker(state, reason)
    end
  end

  defp reply_result(state, {:ok, rendered}) do
    GenServer.reply(state.pending.from, {:ok, rendered})
    {:noreply, clear_pending(state)}
  end

  defp reply_result(state, {:worker_error, reason}) do
    GenServer.reply(state.pending.from, {:error, reason})
    {:noreply, clear_pending(state)}
  end

  defp fail_worker(state, reason) do
    reply_pending(state, {:error, {:invalid_worker_response, reason}})
    {:stop, {:invalid_worker_response, reason}, clear_pending(state)}
  end

  defp clear_pending(%{pending: nil} = state), do: reset_response(state)

  defp clear_pending(state) do
    Process.cancel_timer(state.pending.timer)
    state |> Map.put(:pending, nil) |> reset_response()
  end

  defp reset_response(state) do
    %{state | prefix: <<>>, chunks: [], received: 0, expected: nil}
  end

  defp reply_pending(%{pending: nil}, _), do: :ok
  defp reply_pending(state, reply), do: GenServer.reply(state.pending.from, reply)

  defp validate_options(path) do
    if File.regular?(path), do: :ok, else: {:error, :renderer_not_found}
  end

  defp read_executable(path) do
    with {:ok, %{size: size}} when size <= @maximum_executable_bytes <- File.stat(path),
         {:ok, bytes} when byte_size(bytes) <= @maximum_executable_bytes <- File.read(path) do
      {:ok, bytes}
    else
      {:ok, _} -> {:error, :renderer_binary_too_large}
      {:error, _} -> {:error, :renderer_not_found}
    end
  end

  defp open_staged_worker(path) do
    with {:ok, bytes} <- read_executable(path),
         {:ok, staged_path, build_digest} <- stage_executable(bytes) do
      case open_worker(staged_path) do
        {:ok, port} ->
          {:ok, port, staged_path, build_digest}

        {:error, reason} ->
          cleanup_staged_path(staged_path)
          {:error, reason}
      end
    end
  end

  defp stage_executable(bytes) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    directory = Path.join(System.tmp_dir!(), "frameshift-renderer-#{suffix}")
    staged_path = Path.join(directory, "worker")

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(staged_path, bytes, [:exclusive]),
         :ok <- File.chmod(staged_path, 0o500),
         {:ok, staged_bytes} <- File.read(staged_path),
         true <- staged_bytes == bytes do
      {:ok, staged_path, Digest.sha256(staged_bytes)}
    else
      _ ->
        File.rm_rf(directory)
        {:error, :renderer_stage_failed}
    end
  end

  defp cleanup_staged_path(path) when is_binary(path) do
    File.rm_rf(Path.dirname(path))
    :ok
  end

  defp cleanup_staged_path(_), do: :ok

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout + 1_000
  defp call_timeout(_), do: @default_timeout_ms + 1_000

  defp command_worker(port, request) do
    Port.command(port, request)
    :ok
  rescue
    ArgumentError -> {:error, :worker_unavailable}
  end

  defp open_worker(path) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(path)},
        [:binary, :exit_status, :stream, :use_stdio]
      )

    {:ok, port}
  rescue
    ArgumentError -> {:error, :renderer_start_failed}
  end
end
