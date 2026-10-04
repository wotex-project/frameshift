defmodule Frameshift.Outbox.Service do
  @moduledoc """
  Maintains the host listener for paired pull-capable frames.

  The supervised service inspects durable paired-frame records and resolves the
  single host identity reference used by enabled pull frames. It starts or stops
  `Frameshift.Outbox.TLSServer` as that set changes, with an injected credential
  resolver, task supervisor and explicit bind configuration.

  ## Availability and custody

  `refresh/1` requests reconciliation after pairing/removal; a periodic recheck
  also runs every 30 seconds. `status/1` exposes only listener availability and
  bound port. Conflicting identity references or unavailable credential material
  leave the service unavailable rather than selecting arbitrary custody.

  Listener failure does not clear outboxes, rotate current artwork or delete
  paired records. The service owns network lifecycle only; `Frameshift.Library`
  retains pending intent for a later authenticated contact. Keychain keys stay
  with the native signer; Linux protected PEM stays under operator-provisioned
  service custody and resolves transiently through the same credential port.
  """

  use GenServer

  require Logger

  alias Frameshift.Library
  alias Frameshift.Outbox.TLSServer

  @refresh_ms 30_000

  @doc "Starts a supervised outbox service with an injected credential resolver."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, options, name: name),
      else: GenServer.start_link(__MODULE__, options)
  end

  @doc "Reports only listener availability and the bound port."
  @spec status(GenServer.server()) :: %{available: boolean(), port: non_neg_integer() | nil}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Rechecks paired pull frames after an admission or local removal."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__)

  def refresh(server) when is_atom(server) do
    if Process.whereis(server), do: GenServer.cast(server, :refresh)
    :ok
  end

  def refresh(server) when is_pid(server) do
    if Process.alive?(server), do: GenServer.cast(server, :refresh)
    :ok
  end

  @impl true
  def init(options) do
    state = %{
      library: Keyword.get(options, :library, Library),
      resolver: Keyword.fetch!(options, :resolver),
      task_supervisor: Keyword.fetch!(options, :task_supervisor),
      bind_address: Keyword.get(options, :bind_address, {0, 0, 0, 0}),
      listener: nil,
      reference: nil,
      port: nil,
      failure?: false
    }

    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _, state) do
    available = is_pid(state.listener) and Process.alive?(state.listener)
    {:reply, %{available: available, port: if(available, do: state.port)}, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, reconcile(state)}
  end

  @impl true
  def handle_info(:reconcile, state) do
    next = reconcile(state)
    Process.send_after(self(), :reconcile, @refresh_ms)
    {:noreply, next}
  end

  defp reconcile(state) do
    references =
      state.library
      |> Library.list_paired_frames()
      |> Enum.filter(fn frame ->
        "pull" in List.wrap(get_in(frame, ["capabilities", "transferModes"]))
      end)
      |> Enum.map(fn frame -> Library.get_paired_frame(state.library, frame["frame_id"]) end)
      |> Enum.map(fn
        {:ok, frame} -> frame["credential_ref"]
        _ -> nil
      end)
      |> Enum.uniq()

    case references do
      [] -> %{stop_listener(state) | failure?: false}
      [reference] when is_binary(reference) -> ensure_listener(state, reference)
      _ -> report_unavailable(stop_listener(state))
    end
  end

  defp ensure_listener(%{reference: reference, listener: listener} = state, reference)
       when is_pid(listener) do
    if Process.alive?(listener), do: state, else: start_listener(stop_listener(state), reference)
  end

  defp ensure_listener(state, reference), do: start_listener(stop_listener(state), reference)

  defp start_listener(state, reference) do
    with {module, config} <- state.resolver,
         {:ok, identity} <- module.resolve(reference, config),
         {:ok, listener} <-
           TLSServer.start_link(
             name: nil,
             library: state.library,
             task_supervisor: state.task_supervisor,
             bind_address: state.bind_address,
             port: 0,
             certificate: identity.certificate,
             private_key: identity.private_key
           ),
         {:ok, port} <- TLSServer.port(listener) do
      emit(:started)
      Logger.info("outbox listener available", frameshift_event: :outbox_listener_available)
      %{state | listener: listener, reference: reference, port: port, failure?: false}
    else
      _ -> report_unavailable(state)
    end
  end

  defp report_unavailable(state) do
    emit(:unavailable)

    if not state.failure? do
      Logger.warning("outbox listener unavailable",
        frameshift_event: :outbox_listener_unavailable
      )
    end

    %{state | failure?: true}
  end

  defp stop_listener(%{listener: listener} = state) when is_pid(listener) do
    if Process.alive?(listener), do: GenServer.stop(listener)
    emit(:stopped)
    Logger.info("outbox listener stopped", frameshift_event: :outbox_listener_stopped)
    %{state | listener: nil, reference: nil, port: nil}
  end

  defp stop_listener(state), do: state

  defp emit(state) do
    :telemetry.execute([:frameshift, :outbox, :listener], %{count: 1}, %{state: state})
  end
end
