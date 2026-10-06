defmodule FrameshiftRelease.Command do
  @moduledoc """
  Owns one bounded release-tool command through its actual direct-child exit.

  `run/4` takes an explicitly selected absolute executable, literal argument
  array, absolute working directory and options. Its isolated POSIX worker
  supplies closed child stdin, fairly drains stdout/stderr, and observes the
  exact unreaped child. Success returns complete stdout only after child exit
  zero, both pipe EOFs and successful worker exit within the absolute budget.

  ## Limits and tool selection

  Arguments are UTF-8 without NUL, at most 256 entries, 8 KiB each and 256 KiB
  total. `:stdout_maximum` and `:stderr_maximum` independently default to 64 KiB
  and cannot exceed 16 MiB. `:budget_ms` defaults to 15 seconds and is at most
  15 minutes. `:worker` selects a separately qualified native build; `:env`
  explicitly overwrites or removes inherited variables using binary pairs and
  nil removal. No environment or command is inferred from a release record.

  Source callers own fixed Git/version-reader queries, independent tool identity,
  literal-object/environment policy and source admission. This release-only
  owner invokes no shell itself and adds no application dependency or service.

  ## Refusal and retained custody

  Deadline, output overflow or caller death requests at most one TERM from the
  native owner, which keeps observing direct exit while discarding late output.
  At its own deadline this Elixir owner awaits the worker timer without another
  closing-pipe write. Refusal can outlast the acceptance budget; neither a TERM
  request nor port closure proves exit. Unknown custody remains explicit, and
  stopped descendants or device effects are never inferred from direct exit.

  Errors contain no executable, path, environment, child output or OS exception.
  This module performs no record creation, signing, publication, cleanup or
  automatic retry. Build the worker for the execution OS before calling it.
  """

  @worker Path.expand("../../worker/zig-out/bin/frameshift-release-command", __DIR__)
  @limit 16 * 1024 * 1024
  @errors %{
    1 => :child_launch_refused,
    2 => :child_failed,
    3 => :child_deadline,
    4 => :child_output_limit,
    5 => :caller_stopped,
    6 => :child_output_incomplete,
    7 => :child_custody_unknown
  }

  @doc "Runs an explicitly qualified tool; only complete bounded successful stdout accepts."
  @spec run(String.t(), [String.t()], String.t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def run(executable, arguments, cwd, options \\ []) do
    with {:ok, request, settings} <- request(executable, arguments, cwd, options) do
      caller = self()
      reference = make_ref()
      {owner, monitor} = spawn_monitor(fn -> own(caller, reference, request, settings) end)

      receive do
        {^reference, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^owner, _} ->
          {:error, :child_custody_unknown}
      end
    end
  end

  defp request(executable, arguments, cwd, options) do
    milliseconds = Keyword.get(options, :budget_ms, 15_000)
    stdout = Keyword.get(options, :stdout_maximum, 65536)
    stderr = Keyword.get(options, :stderr_maximum, 65536)
    worker = Keyword.get(options, :worker, @worker)
    environment = Keyword.get(options, :env, [])
    allowed = [:budget_ms, :stdout_maximum, :stderr_maximum, :worker, :env]

    if Keyword.keyword?(options) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and absolute?(executable) and
         absolute?(cwd) and
         is_list(arguments) and length(arguments) <= 256 and Enum.all?(arguments, &string?/1) and
         Enum.sum(Enum.map(arguments, &byte_size/1)) <= 256 * 1024 and
         is_integer(milliseconds) and milliseconds in 1..900_000 and
         is_integer(stdout) and stdout in 1..@limit and is_integer(stderr) and stderr in 1..@limit and
         absolute?(worker) and environment?(environment) do
      body =
        IO.iodata_to_binary([
          <<1, 0, length(arguments)::16, milliseconds::32, stdout::32, stderr::32,
            byte_size(executable)::16, byte_size(cwd)::16>>,
          executable,
          cwd,
          Enum.map(arguments, &[<<byte_size(&1)::16>>, &1])
        ])

      env =
        Enum.map(environment, fn {key, value} ->
          {String.to_charlist(key), if(value == nil, do: false, else: String.to_charlist(value))}
        end)

      {:ok, <<byte_size(body)::32, body::binary>>,
       %{worker: worker, milliseconds: milliseconds, maximum: stdout, env: env}}
    else
      {:error, :invalid_command}
    end
  rescue
    _ -> {:error, :invalid_command}
  end

  defp string?(value),
    do:
      is_binary(value) and byte_size(value) <= 8192 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp absolute?(value), do: string?(value) and Path.type(value) == :absolute

  defp environment?(values) when is_list(values) and length(values) <= 256 do
    keys = Enum.map(values, fn {key, _} -> key end)

    length(keys) == length(Enum.uniq(keys)) and
      Enum.all?(values, fn {key, value} ->
        string?(key) and byte_size(key) in 1..128 and not String.contains?(key, "=") and
          (is_nil(value) or string?(value))
      end)
  end

  defp environment?(_), do: false

  defp own(caller, reference, request, settings) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(caller)
    deadline = System.monotonic_time(:millisecond) + settings.milliseconds

    case open_worker(settings) do
      {:ok, port} -> own_port(caller, reference, request, settings, monitor, deadline, port)
      :error -> send(caller, {reference, {:error, :child_launch_refused}})
    end
  end

  defp open_worker(settings) do
    {:ok,
     Port.open({:spawn_executable, String.to_charlist(settings.worker)}, [
       :binary,
       :exit_status,
       :use_stdio,
       env: settings.env
     ])}
  rescue
    _ -> :error
  end

  defp own_port(caller, reference, request, settings, monitor, deadline, port) do
    state = %{
      caller: caller,
      reference: reference,
      monitor: monitor,
      port: port,
      deadline: deadline,
      maximum: settings.maximum,
      failure: nil,
      output: nil,
      decoder: %{prefix: <<>>, length: nil, chunks: [], received: 0}
    }

    if send_command(port, request),
      do: loop(state),
      else: loop(refuse(state, :child_launch_refused))
  end

  defp loop(state) do
    state =
      if state.deadline && System.monotonic_time(:millisecond) >= state.deadline,
        do: %{state | failure: state.failure || :child_deadline, deadline: nil},
        else: state

    timeout =
      if state.deadline,
        do: max(0, state.deadline - System.monotonic_time(:millisecond)),
        else: :infinity

    port = state.port
    monitor = state.monitor

    receive do
      {^port, {:data, bytes}} ->
        loop(if(state.failure, do: state, else: data(state, bytes)))

      {:DOWN, ^monitor, :process, _, _} ->
        loop(refuse(state, :caller_stopped))

      {^port, {:exit_status, status}} ->
        accepted =
          (status == 0 and not is_nil(state.output) and is_nil(state.failure) and
             state.decoder.prefix == <<>> and is_nil(state.decoder.length) and state.deadline) &&
            System.monotonic_time(:millisecond) < state.deadline

        result =
          if accepted, do: {:ok, state.output}, else: {:error, state.failure || :child_failed}

        send(state.caller, {state.reference, result})

      {:EXIT, ^port, :normal} ->
        loop(state)

      {:EXIT, ^port, _} ->
        send(state.caller, {state.reference, {:error, :child_custody_unknown}})
    after
      timeout -> loop(%{state | failure: state.failure || :child_deadline, deadline: nil})
    end
  end

  defp refuse(state, reason) do
    unless state.failure, do: send_command(state.port, <<1::32, 0>>)
    %{state | failure: state.failure || reason, deadline: nil, output: nil}
  end

  defp send_command(port, bytes) do
    Port.command(port, bytes)
  rescue
    _ -> false
  end

  defp data(state, bytes) do
    case decode(state.decoder, bytes, state.maximum + 12) do
      {:partial, decoder} ->
        %{state | decoder: decoder}

      {:frame, body, rest} ->
        state = %{state | decoder: %{prefix: <<>>, length: nil, chunks: [], received: 0}}
        next = response(state, body)
        if rest == <<>> or next.failure, do: next, else: data(next, rest)

      :error ->
        refuse(state, :invalid_command_response)
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

  defp response(%{output: nil} = state, <<1, 0, 1, 0, size::64, output::binary>>)
       when size == byte_size(output) and size <= state.maximum,
       do: %{state | output: output}

  defp response(state, <<1, 1, category, 0>>) when category in 1..7,
    do: %{
      state
      | failure: state.failure || Map.fetch!(@errors, category),
        deadline: nil,
        output: nil
    }

  defp response(state, _), do: refuse(state, :invalid_command_response)
end
