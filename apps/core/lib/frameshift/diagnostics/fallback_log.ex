defmodule Frameshift.Diagnostics.FallbackLog do
  @moduledoc """
  Admits and installs the private, sanitized OTP fallback logging boundary.

  `prepare/1` creates or checks a directory, requires the final directory to be
  real rather than a symlink and restricts access to the owner. Existing targets
  must be regular files; unsafe file/directory types and permission failures
  return `:unsafe_fallback_log`.

  ## Handler lifecycle

  The OTP rotating handler creates the actual file. Call `secure_file/1` afterward
  to restrict that regular file to mode `0600`; directory access is mode `0700`.
  `install/2` checks the current file and supported archive names, installs one
  error-level rotating handler and secures its initial file. Failure returns a
  finite error and must not stop host services. An existing handler is reused
  only when its complete owned configuration matches; a conflicting handler is
  never reconfigured or removed.

  The handler keeps three archives at a 2 MiB rotation threshold. Equal OTP
  sync/drop thresholds choose dropping before synchronous overload, with a finite
  burst limit. These controls do not promise an atomic mailbox bound or loss-free
  coverage. `status/1` describes actual handler configuration, never private paths,
  credentials, disk durability or audit completeness. Newly rotated files remain
  private through the owner-only directory. `Frameshift.Diagnostics.LogFormatter`
  emits only allowlisted fields rather than exception text or arbitrary metadata.
  """

  alias Frameshift.Diagnostics.LogFormatter

  @handler :frameshift_fallback
  @rotation_bytes 2 * 1024 * 1024
  @archives 3
  @limits %{
    type: :file,
    max_no_bytes: @rotation_bytes,
    max_no_files: @archives,
    compress_on_rotate: false,
    sync_mode_qlen: 256,
    drop_mode_qlen: 256,
    flush_qlen: 512,
    burst_limit_enable: true,
    burst_limit_max_count: 500,
    burst_limit_window_time: 1_000
  }

  @doc "Installs an exact private fallback handler without raising on unavailable storage."
  @spec install(String.t(), atom()) :: :ok | {:error, atom()}
  def install(path, handler \\ @handler)

  def install(path, handler) when is_binary(path) and is_atom(handler) do
    path = Path.expand(path)
    configuration = configuration(path)

    case :logger.get_handler_config(handler) do
      {:ok, existing} ->
        if configuration_matches?(existing, configuration),
          do: prepare(path),
          else: {:error, :fallback_log_conflict}

      {:error, {:not_found, _}} ->
        with :ok <- prepare(path) do
          add_handler(path, handler, configuration)
        end
    end
  rescue
    _ -> {:error, :fallback_log_unavailable}
  catch
    _, _ -> {:error, :fallback_log_unavailable}
  end

  def install(_, _), do: {:error, :unsafe_fallback_log}

  @doc "Reports sanitized handler configuration availability, without claiming write coverage."
  @spec status(atom()) :: map()
  def status(handler \\ @handler) do
    available =
      case :logger.get_handler_config(handler) do
        {:ok, %{config: %{file: file}} = existing} when is_list(file) ->
          configuration_matches?(existing, configuration_from_file(file))

        _ ->
          false
      end

    %{
      "available" => available,
      "state" => if(available, do: "configured", else: "unavailable"),
      "scope" => "handler_configuration",
      "rotationBytes" => @rotation_bytes,
      "archiveCount" => @archives,
      "maximumFiles" => @archives + 1,
      "lossFreeSinceMs" => nil
    }
  end

  defp configuration(path) do
    configuration_from_file(String.to_charlist(path))
  end

  defp configuration_from_file(file) do
    %{
      module: :logger_std_h,
      level: :error,
      formatter: {LogFormatter, %{}},
      config: Map.put(@limits, :file, file)
    }
  end

  defp configuration_matches?(%{config: config} = existing, expected) when is_map(config) do
    Map.take(existing, [:module, :level, :formatter]) ==
      Map.take(expected, [:module, :level, :formatter]) and
      Map.take(config, Map.keys(expected.config)) == expected.config
  end

  defp configuration_matches?(_, _), do: false

  defp add_handler(path, handler, configuration) do
    case :logger.add_handler(handler, :logger_std_h, Map.delete(configuration, :module)) do
      :ok ->
        case secure_file(path) do
          :ok ->
            :ok

          error ->
            :logger.remove_handler(handler)
            error
        end

      _ ->
        {:error, :fallback_log_unavailable}
    end
  end

  @doc "Creates a private diagnostics directory and refuses unsafe existing targets."
  @spec prepare(String.t()) :: :ok | {:error, :unsafe_fallback_log}
  def prepare(path) when is_binary(path) do
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- Bitwise.band(mode, 0o077) == 0,
         :ok <- prepare_files(path) do
      :ok
    else
      _ -> {:error, :unsafe_fallback_log}
    end
  end

  def prepare(_), do: {:error, :unsafe_fallback_log}

  @doc "Restricts the regular file created by the OTP handler to owner-only access."
  @spec secure_file(String.t()) :: :ok | {:error, :unsafe_fallback_log}
  def secure_file(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.chmod(path, 0o600) do
          :ok -> :ok
          _ -> {:error, :unsafe_fallback_log}
        end

      _ ->
        {:error, :unsafe_fallback_log}
    end
  end

  def secure_file(_), do: {:error, :unsafe_fallback_log}

  defp prepare_files(path) do
    paths = [path | Enum.flat_map(0..(@archives - 1), &["#{path}.#{&1}", "#{path}.#{&1}.gz"])]

    Enum.reduce_while(paths, :ok, fn file, :ok ->
      case prepare_target(file) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prepare_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> secure_file(path)
      _ -> {:error, :unsafe_fallback_log}
    end
  end
end
