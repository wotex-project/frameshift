defmodule FrameshiftPlatform.Access.PasswordWork do
  @moduledoc """
  Bounds the companion host's HTTP password work within one BEAM VM.

  `sign_in/2` uses the transport IP and bounded credential parameters supplied by
  `FrameshiftPlatformWeb.SessionController`. It admits six attempts per IP and
  sixty total attempts in a 60-second monotonic window, stores at most 1000 IP
  counters and runs at most two tasks under the owned task supervisor. Refusal
  returns `:limited` or `:unavailable`; accepted work delegates once to
  `FrameshiftPlatform.Access.Authentication.sign_in/1`.

  ## Worker and failure custody

  There is no queued password work. Task results reply to the waiting caller,
  while capacity remains occupied until the task's actual DOWN notification.
  Caller exit does not cancel a native hash or free capacity. Raw credentials,
  upstream errors and token-bearing results are never retained in limiter state
  or emitted as diagnostics. Native work has no hard cancellation deadline.

  Limiter or task-supervisor restart, replacement or abnormal worker exit closes
  admission for the rest of this VM;
  lost counters or uncertain native work do not reopen an empty budget. A full
  VM restart resets the fence and the monotonic window. The named supervisor and
  server options support isolated OTP fixtures; HTTP cannot select these owners.
  These limits do not qualify a deployment with multiple application instances.
  """

  use GenServer
  alias FrameshiftPlatform.Access.Authentication

  @window 60_000
  @maximum_workers 2
  @maximum_ips 1000
  @task_supervisor FrameshiftPlatform.Access.PasswordTasks

  @doc "Starts the owned limiter after its task supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Admits one credential attempt without retries or queued native work."
  @spec sign_in(:inet.ip_address(), map()) ::
          {:ok, FrameshiftPlatform.Access.User.t()}
          | {:error, Authentication.failure() | :limited}
  def sign_in(ip, params), do: GenServer.call(__MODULE__, {:sign_in, ip, params}, :infinity)

  @impl true
  def init(options) do
    supervisor = Keyword.get(options, :task_supervisor, @task_supervisor)
    fence_key = {__MODULE__, supervisor}
    reopened? = :persistent_term.get(fence_key, false)
    :persistent_term.put(fence_key, true)

    case GenServer.whereis(supervisor) do
      nil ->
        {:stop, :missing_task_supervisor}

      pid ->
        {:ok,
         %{
           supervisor: supervisor,
           supervisor_pid: pid,
           supervisor_ref: Process.monitor(pid),
           available: not reopened?,
           started: System.monotonic_time(:millisecond),
           ips: %{},
           total: 0,
           workers: %{}
         }}
    end
  end

  @impl true
  def handle_call({:sign_in, ip, params}, from, state) do
    state = renew_window(state)

    cond do
      not state.available or not Process.alive?(state.supervisor_pid) or
          GenServer.whereis(state.supervisor) != state.supervisor_pid ->
        {:reply, {:error, :unavailable}, %{state | available: false}}

      limited?(state, ip) ->
        {:reply, {:error, :limited}, state}

      true ->
        %Task{ref: ref} =
          Task.Supervisor.async_nolink(state.supervisor, fn -> credentials(params) end,
            shutdown: :infinity
          )

        {:noreply,
         %{
           state
           | total: state.total + 1,
             ips: Map.update(state.ips, ip, 1, &(&1 + 1)),
             workers: Map.put(state.workers, ref, from)
         }}
    end
  catch
    _, _ -> {:reply, {:error, :unavailable}, %{state | available: false}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.workers, ref) do
      {:ok, from} when not is_nil(from) ->
        GenServer.reply(from, result)
        {:noreply, %{state | workers: Map.put(state.workers, ref, nil)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{supervisor_ref: ref} = state),
    do: {:noreply, %{state | available: false}}

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Map.fetch(state.workers, ref) do
      :error ->
        {:noreply, state}

      {:ok, from} ->
        if from, do: GenServer.reply(from, {:error, :unavailable})

        {:noreply,
         %{
           state
           | workers: Map.delete(state.workers, ref),
             available: state.available and reason == :normal and is_nil(from)
         }}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp limited?(state, ip) do
    map_size(state.workers) >= @maximum_workers or state.total >= 60 or
      Map.get(state.ips, ip, 0) >= 6 or
      (not Map.has_key?(state.ips, ip) and map_size(state.ips) >= @maximum_ips)
  end

  defp renew_window(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.started >= @window,
      do: %{state | started: now, ips: %{}, total: 0},
      else: state
  end

  defp credentials(params) do
    Authentication.sign_in(params)
  catch
    _, _ -> {:error, :unavailable}
  end
end
