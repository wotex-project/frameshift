defmodule FrameshiftRelease.Input do
  @moduledoc """
  Holds bounded release-file descriptor custody through Elixir consumption.

  `with_input/3` runs a consumer against provisional bytes while an isolated Zig
  worker retains its no-follow regular-file descriptor. It returns `{:ok, result}`
  only after the worker checks descriptor and named identity again and actually
  exits zero. `read/2` returns admitted bytes; `hash/2` streams an archive in the
  worker and returns `%{bytes: length, sha256: lowercase_hex}`.

  ## Bounds and protection

  Supply `:maximum`; `:minimum` defaults to one. Reads are capped at 16 MiB and
  hashes at 8 GiB. `:budget_ms` defaults to 60 seconds for reads and 15 minutes
  for hashes, and covers admission, consumption and closing custody. Private
  inputs use `:private_key`; independently protected trust uses `:protected_trust`.
  The worker checks owner/mode, full inode identity and nanosecond modification
  and change times. Reading does not compare access time.

  ## Failure and process ownership

  Fixed error atoms contain no input path, bytes or operating-system exception.
  Consumer exceptions are re-raised only after worker exit; caller death sends
  abort from a dedicated monitored owner. Deadline, malformed output or abort
  never promotes late bytes. The owner drains bounded exchanges and retains its
  port until actual exit, which can exceed the budget if an OS syscall stalls.
  Direct exit does not prove unrelated descendant or device effects stopped.

  Build `worker/` with the pinned Zig toolchain before use. The optional `:worker`
  path selects an explicitly qualified tool build, never an untrusted release
  input. Neither this tool nor its worker runs in the host application. It owns
  no release schema, publication, replay or mutable-file cleanup policy.
  """

  @read_limit 16 * 1024 * 1024
  @hash_limit 8 * 1024 * 1024 * 1024
  @worker Path.expand("../../worker/zig-out/bin/frameshift-release-input", __DIR__)

  @doc "Consumes bounded bytes under retained descriptor custody; only checked exit accepts."
  @spec with_input(String.t(), keyword(), (binary() -> result)) ::
          {:ok, result} | {:error, atom()}
        when result: term()
  def with_input(path, options, consumer) when is_function(consumer, 1),
    do: consume(path, options, 1, consumer)

  @doc "Reads at most the explicitly supplied bound through the same custody scope."
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def read(path, options), do: with_input(path, options, & &1)

  @doc "Streams SHA-256 and length, without buffering the archive in either process."
  @spec hash(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def hash(path, options \\ []),
    do: consume(path, Keyword.put_new(options, :maximum, @hash_limit), 2, & &1)

  defp consume(path, options, operation, consumer) do
    with {:ok, request, worker, milliseconds, maximum} <- request(path, options, operation) do
      reference = make_ref()
      caller = self()

      {owner, monitor} =
        spawn_monitor(fn ->
          own(caller, reference, worker, request, milliseconds, maximum, operation)
        end)

      receive do
        {^reference, {:admitted, provisional}} ->
          try do
            result = consumer.(provisional)
            send(owner, {reference, :finish})

            case terminal(reference, monitor) do
              :accepted -> {:ok, result}
              error -> error
            end
          catch
            kind, reason ->
              stack = __STACKTRACE__
              send(owner, {reference, :abort})

              case terminal(reference, monitor) do
                {:error, :worker_custody_unknown} = error -> error
                _ -> :erlang.raise(kind, reason, stack)
              end
          end

        {^reference, {:error, _} = error} ->
          Process.demonitor(monitor, [:flush])
          error

        {:DOWN, ^monitor, :process, ^owner, _} ->
          {:error, :worker_custody_unknown}
      end
    end
  end

  defp terminal(reference, monitor) do
    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, :worker_custody_unknown}
    end
  end

  defp request(path, options, operation) when is_list(options) do
    if Keyword.keyword?(options),
      do: request_keywords(path, options, operation),
      else: {:error, :invalid_bounds}
  end

  defp request(_, _, _), do: {:error, :invalid_bounds}

  defp request_keywords(path, options, operation) do
    minimum = Keyword.get(options, :minimum, 1)
    maximum = Keyword.get(options, :maximum)
    milliseconds = Keyword.get(options, :budget_ms, if(operation == 1, do: 60_000, else: 900_000))
    worker = Keyword.get(options, :worker, @worker)
    private = Keyword.get(options, :private_key, false)
    trust = Keyword.get(options, :protected_trust, false)
    allowed = [:minimum, :maximum, :budget_ms, :worker, :private_key, :protected_trust]

    if is_binary(path) and String.valid?(path) and byte_size(path) in 1..4096 and
         not String.contains?(path, <<0>>) and is_integer(minimum) and minimum >= 0 and
         is_integer(maximum) and maximum >= minimum and
         maximum <= if(operation == 1, do: @read_limit, else: @hash_limit) and
         is_integer(milliseconds) and milliseconds in 1..900_000 and is_binary(worker) and
         Path.type(worker) == :absolute and not String.contains?(worker, <<0>>) and
         is_boolean(private) and is_boolean(trust) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) do
      flags = if(private, do: 1, else: 0) + if(trust, do: 2, else: 0)

      request =
        <<1, operation, flags, 0, minimum::64, maximum::64, milliseconds::32, byte_size(path)::16,
          path::binary>>

      {:ok, request, worker, milliseconds, maximum}
    else
      {:error, :invalid_bounds}
    end
  end

  defp own(caller, reference, worker, request, milliseconds, maximum, operation) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(caller)

    case open_worker(worker) do
      {:ok, port} ->
        <<_::32, minimum::64, _::binary>> = request

        state = %{
          port: port,
          caller: caller,
          reference: reference,
          monitor: monitor,
          operation: operation,
          minimum: minimum,
          maximum: maximum,
          phase: :admitting,
          failure: nil,
          deadline: System.monotonic_time(:millisecond) + milliseconds,
          decoder: %{prefix: <<>>, length: nil, chunks: [], received: 0}
        }

        if command(port, <<byte_size(request)::32, request::binary>>),
          do: loop(state),
          else: loop(abort(state, :input_refused))

      :error ->
        send(caller, {reference, {:error, :worker_unavailable}})
    end
  end

  defp open_worker(worker) do
    {:ok,
     Port.open({:spawn_executable, String.to_charlist(worker)}, [
       :binary,
       :exit_status,
       :use_stdio
     ])}
  rescue
    _ -> :error
  end

  defp loop(state) do
    state =
      if state.deadline && System.monotonic_time(:millisecond) >= state.deadline,
        do: abort(state, :deadline),
        else: state

    timeout =
      if state.deadline,
        do: max(0, state.deadline - System.monotonic_time(:millisecond)),
        else: :infinity

    port = state.port
    reference = state.reference
    monitor = state.monitor

    receive do
      {^port, {:data, bytes}} ->
        loop(if(state.failure, do: state, else: data(state, bytes)))

      {^reference, :finish} when state.phase == :consuming and is_nil(state.failure) ->
        command(state.port, <<1::32, 1>>)
        loop(%{state | phase: :finishing})

      {^reference, :abort} ->
        loop(abort(state, :consumer_refused))

      {:DOWN, ^monitor, :process, _, _} ->
        loop(abort(state, :caller_stopped))

      {^port, {:exit_status, code}} ->
        result =
          if (code == 0 and state.phase == :finished and is_nil(state.failure) and
                state.decoder.prefix == <<>> and is_nil(state.decoder.length) and
                state.deadline) && System.monotonic_time(:millisecond) < state.deadline,
             do: :accepted,
             else: {:error, state.failure || :input_refused}

        send(state.caller, {state.reference, result})

      {:EXIT, ^port, :normal} ->
        loop(state)

      {:EXIT, ^port, _} ->
        send(state.caller, {state.reference, {:error, :worker_custody_unknown}})
    after
      timeout -> loop(abort(state, :deadline))
    end
  end

  defp command(port, body) do
    Port.command(port, body)
  rescue
    ArgumentError -> false
  end

  defp abort(state, error) do
    unless state.failure, do: command(state.port, <<1::32, 0>>)

    %{
      state
      | failure: state.failure || error,
        deadline: nil,
        decoder: %{prefix: <<>>, length: nil, chunks: [], received: 0}
    }
  end

  defp data(state, bytes) do
    maximum = if state.operation == 1, do: state.maximum + 12, else: 44

    case decode(state.decoder, bytes, maximum) do
      {:partial, decoder} ->
        %{state | decoder: decoder}

      {:frame, body, rest} ->
        next =
          response(
            %{state | decoder: %{prefix: <<>>, length: nil, chunks: [], received: 0}},
            body
          )

        if rest == <<>> or next.failure, do: next, else: data(next, rest)

      :error ->
        abort(state, :invalid_response)
    end
  end

  defp decode(%{length: nil} = decoder, bytes, maximum) do
    count = min(4 - byte_size(decoder.prefix), byte_size(bytes))
    <<part::binary-size(^count), rest::binary>> = bytes
    prefix = decoder.prefix <> part

    if byte_size(prefix) < 4 do
      {:partial, %{decoder | prefix: prefix}}
    else
      <<length::32>> = prefix

      if length in 4..maximum,
        do: decode(%{decoder | prefix: <<>>, length: length}, rest, maximum),
        else: :error
    end
  end

  defp decode(decoder, bytes, _maximum) do
    count = min(decoder.length - decoder.received, byte_size(bytes))
    <<part::binary-size(^count), rest::binary>> = bytes
    chunks = [part | decoder.chunks]
    received = decoder.received + count

    if received == decoder.length,
      do: {:frame, IO.iodata_to_binary(Enum.reverse(chunks)), rest},
      else: {:partial, %{decoder | chunks: chunks, received: received}}
  end

  defp response(
         %{phase: :admitting, operation: 1} = state,
         <<1, 0, 1, 0, size::64, body::binary>>
       )
       when size == byte_size(body) and size >= state.minimum and size <= state.maximum do
    send(state.caller, {state.reference, {:admitted, body}})
    %{state | phase: :consuming}
  end

  defp response(
         %{phase: :admitting, operation: 2} = state,
         <<1, 0, 2, 0, size::64, digest::binary-size(32)>>
       )
       when size >= state.minimum and size <= state.maximum do
    send(
      state.caller,
      {state.reference, {:admitted, %{bytes: size, sha256: Base.encode16(digest, case: :lower)}}}
    )

    %{state | phase: :consuming}
  end

  defp response(%{phase: :finishing} = state, <<1, 0, 3, 0>>), do: %{state | phase: :finished}
  # This frame is already terminal: writing abort into a closing pipe can lose
  # the exit-status observation on Linux. Retain the port and await actual exit.
  defp response(state, <<1, 1, 0, 0>>),
    do: %{state | failure: state.failure || :input_refused, deadline: nil}

  defp response(state, _), do: abort(state, :invalid_response)
end
