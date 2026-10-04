defmodule Frameshift.Diagnostics.LogFormatter do
  @moduledoc """
  Formats finite operational records for native and rotating fallback logs.

  Both Logger and OTP formatter entrypoints emit an `FSLOG|` JSON line containing
  an allowlisted event, level, timestamp and validated optional outcome/attempt/
  duration data. Raw messages, paths, exception text and arbitrary third-party
  metadata are discarded. Unclassified events retain only the permitted fields.

  ## Correlation and privacy

  Bounded command/request identifiers are hashed before becoming correlation
  values; only valid attempt IDs and finite duration ranges are retained.
  These values support local investigation without serializing credentials,
  artwork bytes or source paths through a generic inspect operation.

  The formatter does not own collection, audit storage or authorization to read
  logs. `Frameshift.Diagnostics.FallbackLog` admits the file boundary, and native
  release configuration owns the OS/fallback sinks and their lifecycle.
  """

  alias Frameshift.Digest

  @allowed_events ~w(command_completed delivery_attempt ipc_failure outbox_listener_available outbox_listener_stopped outbox_listener_unavailable runtime)
  @allowed_outcomes ~w(succeeded failed replay unknown displayed pending other)

  @doc "Formats one Elixir Logger console record for the macOS native bridge."
  @spec format(atom(), term(), term(), keyword()) :: iodata()
  def format(level, _, _, metadata) do
    encode(level, Map.new(metadata))
  end

  @doc "Formats one OTP logger record for the bounded fallback file."
  @spec format(map(), map()) :: iodata()
  def format(%{level: level, meta: metadata}, _) do
    encode(level, metadata)
  end

  def format(_, _), do: encode(:error, %{})

  @doc "Checks the OTP handler's formatter configuration."
  @spec check_config(map()) :: :ok
  def check_config(_), do: :ok

  defp encode(level, metadata) do
    event = safe_enum(Map.get(metadata, :frameshift_event), @allowed_events, "runtime")

    fields = %{
      "level" => safe_level(level),
      "event" => event,
      "timeMs" => System.os_time(:millisecond)
    }

    fields =
      put_if(
        fields,
        "outcome",
        safe_enum(Map.get(metadata, :frameshift_outcome), @allowed_outcomes)
      )

    correlation_id =
      safe_id(Map.get(metadata, :command_id)) || safe_id(Map.get(metadata, :request_id))

    fields = put_if(fields, "correlationId", correlation_id)
    fields = put_if(fields, "attemptId", safe_attempt_id(Map.get(metadata, :attempt_id)))
    fields = put_if(fields, "durationMs", safe_duration(Map.get(metadata, :duration_ms)))

    ["FSLOG|", Jason.encode!(fields), "\n"]
  end

  defp safe_level(level)
       when level in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency],
       do: Atom.to_string(level)

  defp safe_level(_), do: "error"

  defp safe_enum(value, allowed, fallback \\ nil) do
    encoded = if is_atom(value), do: Atom.to_string(value), else: value
    if encoded in allowed, do: encoded, else: fallback
  end

  defp safe_id(value) when is_binary(value) and byte_size(value) in 1..64,
    do: Digest.sha256(value)

  defp safe_id(_), do: nil

  defp safe_attempt_id(value) when is_binary(value) and byte_size(value) == 32 do
    if String.match?(value, ~r/\A[0-9a-f]{32}\z/), do: value, else: nil
  end

  defp safe_attempt_id(_), do: nil

  defp safe_duration(value) when is_integer(value) and value in 0..3_600_000, do: value
  defp safe_duration(_), do: nil

  defp put_if(fields, _, nil), do: fields
  defp put_if(fields, key, value), do: Map.put(fields, key, value)
end
