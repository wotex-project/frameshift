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
  bootstrap challenge is consumed through `Frameshift.LocalIPC.Token` before the
  command listener starts. Invalid bootstrap or listener configuration prevents
  that boundary from opening instead of accepting unauthenticated commands.

  Renderer and service failures are handled by their supervisors without treating
  unconfirmed delivery as displayed artwork. Durable recovery remains the library
  and frame owners' responsibility; restarting a process is not a new external
  command or permission to discard a pending outcome.
  """

  use Application

  alias Frameshift.Diagnostics.FallbackLog
  alias Frameshift.Diagnostics.LogFormatter
  alias Frameshift.Diagnostics.Metrics
  alias Frameshift.LocalIPC.DiagnosticsServer
  alias Frameshift.LocalIPC.Token
  alias Frameshift.Outbox.Service
  alias Frameshift.Transport.KeychainBroker

  @impl true
  def start(_, _) do
    children =
      [
        {Task.Supervisor, name: Frameshift.TaskSupervisor}
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
      :ok = FallbackLog.prepare(path)

      config = %{
        level: :error,
        formatter: {LogFormatter, %{}},
        config: %{
          type: :file,
          file: String.to_charlist(path),
          max_no_bytes: 2 * 1024 * 1024,
          max_no_files: 3
        }
      }

      case :logger.add_handler(:frameshift_fallback, :logger_std_h, config) do
        :ok -> :ok = FallbackLog.secure_file(path)
        {:error, {:already_exist, _}} -> :ok
        {:error, reason} -> raise "could not start fallback logging: #{inspect(reason)}"
      end
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
      token_path =
        System.get_env("FRAMESHIFT_IPC_TOKEN_FILE") ||
          raise "FRAMESHIFT_IPC_TOKEN_FILE is required when local IPC is enabled"

      token =
        case Token.consume(token_path) do
          {:ok, token} -> token
          {:error, reason} -> raise "could not consume local IPC bootstrap token: #{reason}"
        end

      broker = configure_credential_broker(token)

      [
        {Frameshift.LocalIPC.Server, path: Frameshift.Paths.socket_path(), token: token},
        {DiagnosticsServer, path: Frameshift.Paths.diagnostics_socket_path()}
      ] ++ outbox_children(broker)
    else
      []
    end
  end

  defp outbox_children(nil), do: []

  defp outbox_children(config) do
    [{Service, resolver: {KeychainBroker, config}, task_supervisor: Frameshift.TaskSupervisor}]
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
