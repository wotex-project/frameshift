defmodule Frameshift.Diagnostics.FallbackLog do
  @moduledoc """
  Admits the native fallback log path before an OTP handler opens it.

  `prepare/1` creates or checks a directory, requires the final directory to be
  real rather than a symlink and restricts access to the owner. Existing targets
  must be regular files; unsafe file/directory types and permission failures
  return `:unsafe_fallback_log`.

  ## Handler lifecycle

  The OTP rotating handler creates the actual file. Call `secure_file/1` afterward
  to restrict that regular file to mode `0600`; directory access is mode `0700`.
  This module admits local paths and permissions, not the log message payload or
  rotation policy. `Frameshift.Diagnostics.LogFormatter` separately emits only
  allowlisted operational fields rather than arbitrary exception text or paths.
  """

  @doc "Creates a private diagnostics directory and refuses unsafe existing targets."
  @spec prepare(String.t()) :: :ok | {:error, :unsafe_fallback_log}
  def prepare(path) when is_binary(path) do
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- Bitwise.band(mode, 0o077) == 0,
         :ok <- prepare_target(path) do
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

  defp prepare_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> secure_file(path)
      _ -> {:error, :unsafe_fallback_log}
    end
  end
end
