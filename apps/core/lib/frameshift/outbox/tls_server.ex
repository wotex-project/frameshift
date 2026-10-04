defmodule Frameshift.Outbox.TLSServer do
  @moduledoc """
  Hosts bounded authenticated pull exchanges on the reference TLS listener.

  `start_link/1` requires an explicit bind address/port, certificate, OTP-compatible
  key or signer and task supervisor. TLS handshakes require a certificate whose
  SPKI resolves to exactly one paired pull-capable frame. Only the established
  socket's DER peer certificate reaches `Frameshift.Outbox.HTTP1`.

  ## Connection lifecycle

  Each accepted connection runs one finite exchange in a separately supervised
  worker with handshake/request deadlines. Strict framing, bounded concurrency
  and response limits prevent a slow client from becoming unbounded listener
  work. `port/1` reports the bound port, including an OS-selected test port.

  The owner monitors its acceptor and closes the listener during termination.
  It does not obtain or persist host identity; non-exportable Keychain keys use
  the supplied signing bridge. Request fields cannot impersonate a different
  paired frame, and a successful transfer alone cannot confirm physical display.
  """

  use GenServer

  alias Frameshift.Library
  alias Frameshift.Outbox.HTTP1
  alias Frameshift.Transport.SPKIPin

  @handshake_timeout_ms 5_000
  @request_timeout_ms 5_000
  @accepted_chain_errors [:unknown_ca, :selfsigned_peer]

  defmodule State do
    @moduledoc """
    Owns one pull-outbox TLS listener and its supervised accept loop.

    The state requires listener and acceptor handles. The server monitors acceptor
    loss and closes the listener on termination; separate bounded tasks own accepted
    connections and one finite HTTP exchange each.

    ## Recovery scope

    `Frameshift.Outbox.TLSServer` constructs this transient value after explicit
    TLS/bind configuration succeeds. Listener replacement does not reset durable
    outbox revisions or imply acknowledgement. Those records remain with
    `Frameshift.Library`, while each new peer must authenticate again through TLS.
    """

    @enforce_keys [:acceptor, :listener]
    defstruct [:acceptor, :listener]

    @type t :: %__MODULE__{acceptor: pid(), listener: term()}
  end

  @doc "Starts a listener with explicit TLS identity and a bounded task supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Returns the bound port, including an OS-selected port used by tests."
  @spec port(GenServer.server()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(options) do
    library = Keyword.get(options, :library, Library)
    task_supervisor = Keyword.fetch!(options, :task_supervisor)
    bind_address = Keyword.fetch!(options, :bind_address)
    port = Keyword.fetch!(options, :port)
    certificate = Keyword.fetch!(options, :certificate)
    private_key = Keyword.fetch!(options, :private_key)

    with :ok <- validate_options(bind_address, port, certificate, private_key),
         {:ok, listener} <- listen(bind_address, port, certificate, private_key, library) do
      finish_start(task_supervisor, listener, library)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp finish_start(task_supervisor, listener, library) do
    case start_acceptor(task_supervisor, listener, library) do
      {:ok, acceptor} ->
        Process.monitor(acceptor)
        {:ok, %State{acceptor: acceptor, listener: listener}}

      {:error, reason} ->
        :ssl.close(listener)
        {:stop, reason}
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
    {:stop, {:acceptor_stopped, reason}, state}
  end

  @impl true
  def terminate(_, %State{listener: listener}) do
    :ssl.close(listener)
    :ok
  end

  @doc "Pins a presented client certificate during the OTP TLS verification callback."
  @spec verify_client(tuple(), term(), map()) ::
          {:valid, map()} | {:unknown, map()} | {:fail, term()}
  def verify_client(_, {:bad_cert, reason}, state)
      when reason in @accepted_chain_errors,
      do: {:valid, state}

  def verify_client(_, {:bad_cert, reason}, _),
    do: {:fail, {:bad_cert, reason}}

  def verify_client(_, {:extension, _}, state), do: {:unknown, state}
  def verify_client(_, :valid, state), do: {:valid, state}

  def verify_client(certificate, :valid_peer, %{library: library} = state) do
    with {:ok, digest} <- SPKIPin.fingerprint(certificate),
         fingerprint = "sha256:" <> Base.encode16(digest, case: :lower),
         {:ok, %{"capabilities" => %{"transferModes" => modes}}} <-
           Library.get_paired_frame_by_spki(library, fingerprint),
         true <- "pull" in modes do
      {:valid, Map.put(state, :matched, true)}
    else
      _ -> {:fail, :unpaired_frame}
    end
  end

  def verify_client(_, _, state), do: {:unknown, state}

  defp validate_options(bind_address, port, certificate, private_key) do
    if valid_address?(bind_address) and is_integer(port) and port in 0..65_535 and
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

  defp listen(bind_address, port, certificate, private_key, library) do
    :ssl.listen(port,
      ip: bind_address,
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
      verify_fun: {&verify_client/3, %{library: library}},
      versions: [:"tlsv1.3"],
      max_handshake_size: 65_536,
      session_tickets: :disabled,
      alpn_preferred_protocols: ["http/1.1"]
    )
  end

  defp start_acceptor(task_supervisor, listener, library) do
    Task.Supervisor.start_child(task_supervisor, fn ->
      accept_loop(task_supervisor, listener, library)
    end)
  end

  defp accept_loop(task_supervisor, listener, library) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        hand_off(task_supervisor, socket, library)
        accept_loop(task_supervisor, listener, library)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:outbox_accept_failed, reason})
    end
  end

  defp hand_off(task_supervisor, socket, library) do
    case Task.Supervisor.start_child(task_supervisor, fn ->
           receive do
             {:serve, ^socket} -> serve(socket, library)
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

  defp serve(socket, library) do
    case :ssl.handshake(socket, @handshake_timeout_ms) do
      {:ok, established} ->
        serve_authenticated(established, library)
        :ssl.close(established)

      {:error, _} ->
        :ssl.close(socket)
    end
  end

  defp serve_authenticated(socket, library) do
    with {:ok, certificate} <- :ssl.peercert(socket),
         deadline = System.monotonic_time(:millisecond) + @request_timeout_ms do
      read_exchange(socket, library, certificate, <<>>, deadline)
    end
  end

  defp read_exchange(socket, library, certificate, wire, deadline) do
    case HTTP1.exchange(library, certificate, wire) do
      {:ok, response} ->
        :ssl.send(socket, response)

      :more ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 and byte_size(wire) < HTTP1.maximum_wire_bytes() do
          receive_more(socket, library, certificate, wire, deadline, remaining)
        else
          :ok
        end
    end
  end

  defp receive_more(socket, library, certificate, wire, deadline, remaining) do
    case :ssl.recv(socket, 0, remaining) do
      {:ok, bytes} -> read_exchange(socket, library, certificate, wire <> bytes, deadline)
      {:error, _} -> :ok
    end
  end
end
