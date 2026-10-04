defmodule Frameshift.Application do
  @moduledoc """
  Starts the durable native core and its configured local boundaries.

  The application supervises library state, the bounded task supervisor and the
  configured renderer, telemetry, outbox and IPC services. Release configuration
  selects optional children; the independent companion web platform is not started
  by this application. Services receive the owned library and process boundaries
  rather than opening additional writers.

  ## Startup and custody

  `Frameshift.Paths` supplies relocatable data/socket locations. The shell's
  Mac bootstrap challenge is consumed through `Frameshift.LocalIPC.Token` before
  its command listener starts. Linux may explicitly select distinct control and
  observer groups; that policy accepts no bootstrap token or Mac credential
  broker. Invalid bootstrap/group/listener configuration prevents the boundary
  from opening instead of accepting unauthenticated commands.

  Explicit Linux protected-file custody resolves transient TLS identity through
  `Frameshift.Transport.ProtectedFile` for direct delivery and the pull listener.
  Its directory is admitted before listeners start; missing keys leave network
  delivery unavailable while catalog and diagnostics continue. No private key
  enters an environment variable, command or metadata database.

  Renderer and service failures are handled by their supervisors without treating
  unconfirmed delivery as displayed artwork. Durable recovery remains the library
  and frame owners' responsibility; restarting a process is not a new external
  command or permission to discard a pending outcome.

  Ordinary supervised tasks have a sixty-four-child admission ceiling. Read-only
  diagnostics owns a separate seventeen-child supervisor so command/task pressure
  cannot consume its acceptor and sixteen client slots. Listener-local limits
  still apply; neither process bound establishes measured memory or disk behavior.
  """

  use Application

  alias Frameshift.Diagnostics.FallbackLog
  alias Frameshift.Diagnostics.Metrics
  alias Frameshift.LocalIPC.DiagnosticsServer
  alias Frameshift.LocalIPC.SocketDirectory
  alias Frameshift.LocalIPC.Token
  alias Frameshift.Outbox.Service
  alias Frameshift.Transport.KeychainBroker
  alias Frameshift.Transport.ProtectedFile

  @impl true
  def start(_, _) do
    children =
      [
        {Task.Supervisor, name: Frameshift.TaskSupervisor, max_children: 64}
      ] ++ library_children() ++ metrics_children() ++ renderer_children() ++ local_ipc_children()

    case Supervisor.start_link(children, strategy: :one_for_one, name: Frameshift.Supervisor) do
      {:ok, _} = started ->
        configure_fallback_logging()
        started

      error ->
        error
    end
  end

  defp configure_fallback_logging do
    if Application.get_env(:frameshift_core, :start_local_ipc, false) do
      directory = Path.join(Frameshift.Paths.data_dir(), "diagnostics")
      path = Path.join(directory, "core-fallback.log")
      # Logging availability is observable through diagnostic health and cannot
      # take down the already-started authoritative services.
      FallbackLog.install(path)
    end
  end

  defp library_children do
    if Application.fetch_env!(:frameshift_core, :start_library) do
      [{Frameshift.Library, data_dir: Frameshift.Paths.data_dir()}]
    else
      []
    end
  end

  defp renderer_children do
    if Application.fetch_env!(:frameshift_core, :start_renderer) do
      [{Frameshift.Renderer, path: Application.fetch_env!(:frameshift_core, :renderer_path)}]
    else
      []
    end
  end

  defp metrics_children do
    if Application.fetch_env!(:frameshift_core, :start_library) do
      [Metrics]
    else
      []
    end
  end

  defp local_ipc_children do
    if Application.fetch_env!(:frameshift_core, :start_local_ipc) do
      diagnostics = diagnostics_options()
      {commands, broker} = command_options(diagnostics)

      [
        Supervisor.child_spec(
          {Task.Supervisor, name: Frameshift.DiagnosticsTaskSupervisor, max_children: 17},
          id: Frameshift.DiagnosticsTaskSupervisor
        ),
        {Frameshift.LocalIPC.Server, commands},
        {DiagnosticsServer, diagnostics}
      ] ++ outbox_children(broker)
    else
      []
    end
  end

  defp command_options(diagnostics) do
    case System.get_env("FRAMESHIFT_CONTROL_GID") do
      nil ->
        private_command_options()

      value ->
        with {:ok, gid} <- group_gid(value),
             observer when is_integer(observer) and observer != gid <- diagnostics[:group_gid],
             true <- is_nil(System.get_env("FRAMESHIFT_IPC_TOKEN_FILE")),
             true <- is_nil(System.get_env("FRAMESHIFT_CREDENTIAL_SOCKET")) do
          {[path: Frameshift.Paths.socket_path(), group_gid: gid], configure_linux_credentials()}
        else
          _ -> raise "Linux control group requires distinct observer access and no token broker"
        end
    end
  end

  defp private_command_options do
    if System.get_env("FRAMESHIFT_CREDENTIAL_DIRECTORY"),
      do: raise("protected Linux credentials require explicit Linux group policy")

    token_path =
      System.get_env("FRAMESHIFT_IPC_TOKEN_FILE") ||
        raise "FRAMESHIFT_IPC_TOKEN_FILE is required when local IPC is enabled"

    token =
      case Token.consume(token_path) do
        {:ok, token} -> token
        {:error, reason} -> raise "could not consume local IPC bootstrap token: #{reason}"
      end

    broker = configure_credential_broker(token)
    resolver = if broker, do: {KeychainBroker, broker}, else: nil
    {[path: Frameshift.Paths.socket_path(), token: token], resolver}
  end

  defp diagnostics_options do
    path = Frameshift.Paths.diagnostics_socket_path()

    options = [path: path, task_supervisor: Frameshift.DiagnosticsTaskSupervisor]

    case System.get_env("FRAMESHIFT_DIAGNOSTICS_GID") do
      nil ->
        options

      value ->
        with {:ok, gid} <- group_gid(value),
             true <- Path.dirname(path) != Path.dirname(Frameshift.Paths.socket_path()) do
          Keyword.put(options, :group_gid, gid)
        else
          _ -> raise "Linux diagnostics group requires a valid GID and separate socket directory"
        end
    end
  end

  defp group_gid(value) when byte_size(value) in 1..10 do
    with {:unix, :linux} <- :os.type(),
         {gid, ""} when gid in 1..4_294_967_294 <- Integer.parse(value),
         true <- value == Integer.to_string(gid) do
      {:ok, gid}
    else
      _ -> {:error, :invalid_socket_group}
    end
  end

  defp group_gid(_), do: {:error, :invalid_socket_group}

  defp outbox_children(nil), do: []

  defp outbox_children(resolver) do
    [{Service, resolver: resolver, task_supervisor: Frameshift.TaskSupervisor}]
  end

  defp configure_linux_credentials do
    case System.get_env("FRAMESHIFT_CREDENTIAL_DIRECTORY") do
      nil ->
        nil

      directory ->
        with {:ok, uid} <- SocketDirectory.service_uid(),
             {:ok, %{uid: ^uid} = config} <- ProtectedFile.configure(directory) do
          resolver = {ProtectedFile, config}
          Application.put_env(:frameshift_core, :direct_delivery, credential_resolver: resolver)
          resolver
        else
          _ -> raise "protected Linux credential directory failed local admission"
        end
    end
  end

  defp configure_credential_broker(token) do
    case System.get_env("FRAMESHIFT_CREDENTIAL_SOCKET") do
      nil ->
        nil

      path ->
        expanded = Path.expand(path)

        with true <- Path.dirname(expanded) == Path.dirname(Frameshift.Paths.socket_path()),
             {:ok, %File.Stat{type: :other, mode: mode, uid: uid}} <- File.lstat(expanded),
             {:ok, %File.Stat{type: :directory, uid: ^uid, mode: directory_mode}} <-
               File.lstat(Path.dirname(expanded)),
             true <-
               Bitwise.band(mode, 0o077) == 0 and
                 Bitwise.band(directory_mode, 0o077) == 0 do
          broker = %{socket_path: expanded, token: token}

          Application.put_env(:frameshift_core, :direct_delivery,
            credential_resolver: {KeychainBroker, broker}
          )

          Application.put_env(:frameshift_core, :pairing, resolver: {KeychainBroker, broker})

          broker
        else
          _ -> raise "credential broker socket failed local admission"
        end
    end
  end
end
