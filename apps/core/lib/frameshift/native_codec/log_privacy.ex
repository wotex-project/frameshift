defmodule Frameshift.NativeCodec.LogPrivacy do
  @moduledoc """
  Prevents marked codec-process fault reports from exposing original image bytes.

  Exile owns a bounded input chunk in its GenServer state while native stdin is
  blocked. An upstream callback fault could include that chunk in OTP's crash
  report. `install/0` admits one exact primary Logger filter; `mark/1` sets its
  process metadata through the public OTP system interface before source bytes
  are sent. Startup faults before marking contain no original artwork.
  Upload finish tasks use `mark_current/0` before reading their private stage;
  task fault reports cannot become an alternative source or custody channel.

  ## Scope and refusal

  The filter drops only records with this explicit private-process marker.
  Other host and dependency records retain their existing handlers and policy.
  The host owner still returns finite IO, exit or custody errors; raw upstream
  fault text is not an additional diagnostic channel. A conflicting filter or
  unavailable process marker refuses work before transmitting original bytes.
  This protects operational logging, not same-user debugger or administrator
  access to the host process. Worker stderr is separately disabled by its owner.
  """

  @filter :frameshift_native_codec_privacy
  @marker :frameshift_private_codec_process

  @doc "Admits the exact codec privacy filter without replacing other Logger policy."
  @spec install() :: :ok | {:error, :codec_log_privacy_unavailable}
  def install do
    expected = {&__MODULE__.filter/2, nil}

    case List.keyfind(:logger.get_primary_config().filters, @filter, 0) do
      {@filter, ^expected} -> :ok
      nil -> install_filter(expected)
      _ -> {:error, :codec_log_privacy_unavailable}
    end
  end

  @doc "Marks an admitted Exile process before its first original-byte write."
  @spec mark(Exile.Process.t()) :: :ok | {:error, :codec_log_privacy_unavailable}
  def mark(process) do
    :sys.replace_state(process.pid, fn state ->
      mark_current()
      state
    end)

    :ok
  catch
    _, _ -> {:error, :codec_log_privacy_unavailable}
  end

  @doc "Marks an owned original-byte task before reading source or retaining upload custody."
  @spec mark_current() :: :ok
  def mark_current, do: :logger.update_process_metadata(%{@marker => true})

  @doc "Drops marked private worker records and leaves every other event undecided."
  @spec filter(:logger.log_event(), term()) :: :stop | :ignore
  def filter(%{meta: %{@marker => true}}, _), do: :stop
  def filter(_, _), do: :ignore

  defp install_filter(expected) do
    case :logger.add_primary_filter(@filter, expected) do
      :ok -> :ok
      _ -> {:error, :codec_log_privacy_unavailable}
    end
  end
end
