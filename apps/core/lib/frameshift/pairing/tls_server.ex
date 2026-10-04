defmodule Frameshift.Pairing.TLSServer do
  @moduledoc """
  Hosts bounded commissioning exchanges on a TLS 1.3 listener.

  `start_link/1` receives an explicit frame TLS identity, bind configuration,
  simulator owner and supervised task boundary. Handshakes require a client
  certificate and proof of private-key possession. Explicitly accepted commissioning
  chain conditions do not themselves grant pairing authority.

  ## Physical-window dispatch

  The established peer DER is passed directly to `Frameshift.Pairing.HTTP1` and
  the physical-window state machine. This listener cannot open pairing mode and
  exposes no ordinary frame mutations. Each accepted connection has bounded
  handshake/request work in a separate supervised task; `port/1` reports its port.

  The owner monitors the accept loop and closes the listener on termination.
  Successful software TLS/window exchanges do not qualify firmware key storage
  or the device's physical input. Normal paired operations use their own admitted
  Thing Forms and authenticated custody after commissioning.
  """

  use GenServer

  alias Frameshift.Pairing.HTTP1

  @handshake_timeout_ms 5_000
  @request_timeout_ms 5_000
  @accepted_chain_errors [:unknown_ca, :selfsigned_peer]

  defmodule State do
    @moduledoc """
    Owns the commissioning TLS listener and supervised accept loop.

    The listener and acceptor are required process handles; each connection runs
    in a separate bounded task. Acceptor loss terminates the owner and shutdown
    closes the listen socket rather than leaving commissioning access orphaned.

    ## Physical authority

    `Frameshift.Pairing.TLSServer` constructs this value during listener startup.
    It contains no physical-window authority and cannot open pairing mode or restore
    a consumed secret. Persisted host authorization remains with the frame's
    separate window/store owner across listener restarts.
    """

    @enforce_keys [:acceptor, :listener]
    defstruct [:acceptor, :listener]

    @type t :: %__MODULE__{acceptor: pid(), listener: term()}
  end

  @doc "Starts the pairing listener with an explicit frame TLS identity."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Returns the bound port, including an OS-selected test port."
  @spec port(GenServer.server()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(options) do
    frame = Keyword.fetch!(options, :frame)
    workers = Keyword.fetch!(options, :task_supervisor)
    address = Keyword.fetch!(options, :bind_address)
    port = Keyword.fetch!(options, :port)
    certificate = Keyword.fetch!(options, :certificate)
    private_key = Keyword.fetch!(options, :private_key)

    with :ok <- validate_options(address, port, certificate, private_key),
         {:ok, listener} <- listen(address, port, certificate, private_key),
         {:ok, acceptor} <- start_acceptor(workers, listener, frame) do
      Process.monitor(acceptor)
      {:ok, %State{acceptor: acceptor, listener: listener}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _, %State{listener: listener} = state) do
    result =
      case :ssl.sockname(listener) do
        {:ok, {_, port}} -> {:ok, port}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(
        {:DOWN, _, :process, acceptor, reason},
        %State{acceptor: acceptor} = state
      ) do
    {:stop, {:pairing_acceptor_stopped, reason}, state}
  end

  @impl true
  def terminate(_, %State{listener: listener}) do
    :ssl.close(listener)
    :ok
  end

  @doc "Admits a commissioning certificate while TLS verifies key possession."
  @spec verify_client(tuple(), term(), term()) ::
          {:valid, term()} | {:unknown, term()} | {:fail, term()}
  def verify_client(_, {:bad_cert, reason}, state)
      when reason in @accepted_chain_errors,
      do: {:valid, state}

  def verify_client(_, {:bad_cert, reason}, _),
    do: {:fail, {:bad_cert, reason}}

  def verify_client(_, {:extension, _}, state), do: {:unknown, state}
  def verify_client(_, :valid_peer, state), do: {:valid, state}
  def verify_client(_, :valid, state), do: {:valid, state}
  def verify_client(_, _, state), do: {:unknown, state}

  defp validate_options(address, port, certificate, private_key) do
    if valid_address?(address) and is_integer(port) and port in 0..65_535 and
         is_binary(certificate) and byte_size(certificate) in 1..65_536 and
         (match?({_type, _value}, private_key) or is_map(private_key)) do
      :ok
    else
      {:error, :invalid_listener_options}
    end
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    address |> Tuple.to_list() |> Enum.all?(&(&1 in 0..255))
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    address |> Tuple.to_list() |> Enum.all?(&(&1 in 0..65_535))
  end

  defp valid_address?(_), do: false

  defp listen(address, port, certificate, private_key) do
    :ssl.listen(port,
      ip: address,
      active: false,
      mode: :binary,
      reuseaddr: true,
      backlog: 16,
      cert: certificate,
      key: private_key,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      certificate_authorities: false,
      cacerts: [],
      verify_fun: {&verify_client/3, nil},
      versions: [:"tlsv1.3"],
      max_handshake_size: 65_536,
      session_tickets: :disabled,
      alpn_preferred_protocols: ["http/1.1"]
    )
  end

  defp start_acceptor(workers, listener, frame) do
    case Task.Supervisor.start_child(workers, fn -> accept_loop(workers, listener, frame) end) do
      {:ok, acceptor} ->
        {:ok, acceptor}

      {:error, reason} ->
        :ssl.close(listener)
        {:error, reason}
    end
  end

  defp accept_loop(workers, listener, frame) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        hand_off(workers, socket, frame)
        accept_loop(workers, listener, frame)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:pairing_accept_failed, reason})
    end
  end

  defp hand_off(workers, socket, frame) do
    case Task.Supervisor.start_child(workers, fn ->
           receive do
             {:serve, ^socket} -> serve(socket, frame)
           after
             @handshake_timeout_ms -> :ssl.close(socket)
           end
         end) do
      {:ok, worker} ->
        case :ssl.controlling_process(socket, worker) do
          :ok -> send(worker, {:serve, socket})
          {:error, _} -> :ssl.close(socket)
        end

      {:error, _} ->
        :ssl.close(socket)
    end
  end

  defp serve(socket, frame) do
    case :ssl.handshake(socket, @handshake_timeout_ms) do
      {:ok, established} ->
        serve_authenticated(established, frame)
        :ssl.close(established)

      {:error, _} ->
        :ssl.close(socket)
    end
  end

  defp serve_authenticated(socket, frame) do
    with {:ok, certificate} <- :ssl.peercert(socket),
         deadline = System.monotonic_time(:millisecond) + @request_timeout_ms do
      read_exchange(socket, frame, certificate, <<>>, deadline)
    end
  end

  defp read_exchange(socket, frame, certificate, wire, deadline) do
    case HTTP1.exchange(frame, certificate, wire, System.system_time(:millisecond)) do
      {:ok, response} ->
        :ssl.send(socket, response)

      :more ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 and byte_size(wire) < HTTP1.maximum_wire_bytes() do
          receive_more(socket, frame, certificate, wire, deadline, remaining)
        else
          :ok
        end
    end
  end

  defp receive_more(socket, frame, certificate, wire, deadline, remaining) do
    case :ssl.recv(socket, 0, remaining) do
      {:ok, bytes} -> read_exchange(socket, frame, certificate, wire <> bytes, deadline)
      {:error, _} -> :ok
    end
  end
end
