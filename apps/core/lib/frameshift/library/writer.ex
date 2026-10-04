defmodule Frameshift.Library.Writer do
  @moduledoc """
  Runs SQLite mutations through the library's single transaction owner.

  `transaction/2` invokes one immediate Exqlite transaction on the connection
  already owned by `Frameshift.Library`. The function receives that same
  connection; it must not open a second writer or release database handles to IPC.
  Domain and audit changes belong inside the originating transaction.

  ## Outcomes and diagnostics

  SQLite statement failures roll back and return an error. `unwrap/1` maps
  completed transactions and database failures to the public storage result;
  other programming exceptions retain their normal fault behavior.
  Every attempt emits bounded transaction duration/outcome telemetry after the
  result is known. Metrics are operational observations, not a transaction receipt.

  Filesystem placement and external network effects have their own recovery
  owners; a SQLite rollback is not an atomic rollback of those other systems.
  """

  @doc "Runs one immediate transaction and reports its storage outcome."
  @spec transaction(pid(), (pid() -> term())) :: {:ok, term()} | {:error, term()}
  def transaction(connection, function) when is_function(function, 1) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        Exqlite.transaction(connection, function, mode: :immediate)
      rescue
        error in Exqlite.Error -> {:error, error}
      end

    :telemetry.execute(
      [:frameshift, :storage, :transaction],
      %{duration_ms: max(0, System.monotonic_time(:millisecond) - started)},
      %{outcome: if(match?({:ok, _}, result), do: :succeeded, else: :failed)}
    )

    result
  end

  @doc "Unwraps a completed mutation and maps SQLite errors to the public storage shape."
  @spec unwrap({:ok, term()} | {:error, term()}) :: term() | {:error, term()}
  def unwrap({:ok, reply}), do: reply
  def unwrap({:error, %Exqlite.Error{message: message}}), do: {:error, {:database, message}}
  def unwrap({:error, reason}), do: {:error, reason}
end
