defmodule Frameshift.CLIInput do
  @moduledoc """
  Reads one bounded transient CLI input with a finite owned-task deadline.

  `read/2` takes an IO device and an admitted byte ceiling, reads at most that
  ceiling plus one byte and requires the input stream to close. Empty, oversized,
  failed or withheld input returns a finite error. The caller's parser still
  owns the exact bootstrap or PEM grammar; successful reading grants no command,
  credential or device authority.

  ## Reader lifetime

  A five-second absolute deadline applies to the entire read. The calling clean
  CLI VM owns the reader task and kills it on timeout; it does not start the host
  or use its task supervisor. The IO device itself remains caller-owned. Input
  bytes never enter logs, argv, a staging file or the error result. The maximum
  supported ceiling is 128 KiB, covering physical bootstrap and offline PEM
  intake without creating an unbounded general file-transfer interface.
  """

  @doc "Reads one nonempty closed input stream, refusing overflow or a reader deadline."
  @spec read(IO.device(), pos_integer()) :: {:ok, binary()} | {:error, :invalid_input}
  def read(device, maximum) when is_integer(maximum) and maximum in 1..131_072 do
    deadline = System.monotonic_time(:millisecond) + 5_000
    task = Task.async(fn -> bytes(device, maximum + 1) end)
    result = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, bytes}
      when is_binary(bytes) and byte_size(bytes) >= 1 and byte_size(bytes) <= maximum ->
        if System.monotonic_time(:millisecond) <= deadline,
          do: {:ok, bytes},
          else: {:error, :invalid_input}

      _ ->
        {:error, :invalid_input}
    end
  end

  def read(_, _), do: {:error, :invalid_input}

  defp bytes(device, count) do
    IO.binread(device, count)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
