defmodule Frameshift.LocalIPC.Token do
  @moduledoc """
  Consumes the private shell-to-core launch challenge file.

  `consume/1` accepts a bounded path, checks the opened file is a user-only regular
  file of exactly 64 bytes and reads the lowercase hexadecimal token. It closes
  and removes the file before returning the admitted value; malformed encoding,
  unsafe permissions, file type and I/O failures are explicit errors.

  ## One-use bootstrap, launch-long authentication

  The file is one-use bootstrap custody, not a persistent credential record.
  The returned token authenticates local command requests for that core launch;
  it must not enter recipes, snapshots or ordinary logs. Application startup
  consumes it before opening `Frameshift.LocalIPC.Server`.

  This module does not generate the random challenge, start a listener or authorize
  read-only diagnostics. The launching shell owns creation and the diagnostics
  endpoint independently checks operating-system peer credentials.
  """

  @token_pattern ~r/^[0-9a-f]{64}$/

  @spec consume(String.t()) :: {:ok, String.t()} | {:error, atom() | File.posix()}
  def consume(path) when is_binary(path) and byte_size(path) in 1..1_024 do
    expanded = Path.expand(path)

    with {:ok, file} <- File.open(expanded, [:read, :binary]),
         result <- read_token(file),
         :ok <- File.close(file),
         :ok <- File.rm(expanded) do
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def consume(_), do: {:error, :invalid_token_path}

  defp read_token(file) do
    with {:ok, info} <- :file.read_file_info(file),
         stat = File.Stat.from_record(info),
         :ok <- validate_stat(stat),
         token when is_binary(token) <- IO.binread(file, 65),
         true <- Regex.match?(@token_pattern, token) do
      {:ok, token}
    else
      :eof -> {:error, :invalid_ipc_token}
      false -> {:error, :invalid_ipc_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_stat(%File.Stat{type: :regular, size: 64, mode: mode}) do
    if Bitwise.band(mode, 0o077) == 0,
      do: :ok,
      else: {:error, :unsafe_token_permissions}
  end

  defp validate_stat(%File.Stat{type: :regular}), do: {:error, :invalid_ipc_token}
  defp validate_stat(%File.Stat{}), do: {:error, :invalid_token_file}
end
