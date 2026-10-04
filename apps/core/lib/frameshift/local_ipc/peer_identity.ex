defmodule Frameshift.LocalIPC.PeerIdentity do
  @moduledoc """
  Reads local socket peer identity from operating-system credentials.

  `uid/1` returns the effective peer UID for a connected Unix-domain socket.
  Darwin uses `LOCAL_PEERCRED`/`struct xucred`; Linux uses `SO_PEERCRED` with a
  native fallback when the OTP representation is unavailable. Invalid credential
  layout or unsupported operating systems return errors rather than a default UID.

  ## Consumer authorization

  `credentials/1` exposes Linux PID, UID and primary GID where supported.
  Callers compare these kernel-reported values with their admitted endpoint policy;
  request JSON and filesystem path ownership cannot choose a peer's identity.
  `Frameshift.LocalIPC.DiagnosticsServer` uses private UID or Linux group policy.
  `inet_credentials/1` supports the command listener's public `:gen_tcp` transport
  through `:inet.getopts/2`. It never borrows or duplicates a private OTP file
  descriptor. The shared native decoder requires exactly twelve bytes and valid
  PID/UID/GID ranges; decoding caller bytes alone does not authenticate a peer.

  Peer identity proves the local connection's OS credential, not the application's
  role, launch token or payload validity. Protocol parsing and any additional
  command authorization remain the consuming server's responsibility.
  """

  defguardp account_id?(id) when is_integer(id) and id in 0..4_294_967_294

  @doc "Returns the peer's effective UID or an error."
  @spec uid(:socket.socket()) :: {:ok, non_neg_integer()} | {:error, term()}
  def uid(socket) do
    case :os.type() do
      {:unix, :darwin} -> darwin_uid(socket)
      {:unix, :linux} -> linux_uid(socket)
      _ -> {:error, :unsupported_peer_identity}
    end
  end

  @doc "Returns the Linux kernel PID, UID, and primary GID for one connected Unix socket."
  @spec credentials(:socket.socket()) ::
          {:ok, %{pid: pos_integer(), uid: non_neg_integer(), gid: non_neg_integer()}}
          | {:error, term()}
  def credentials(socket) do
    case :os.type() do
      {:unix, :linux} -> linux_credentials(socket)
      _ -> {:error, :unsupported_peer_identity}
    end
  end

  @doc "Reads Linux kernel credentials from a connected public OTP inet socket."
  @spec inet_credentials(:gen_tcp.socket()) ::
          {:ok, %{pid: pos_integer(), uid: non_neg_integer(), gid: non_neg_integer()}}
          | {:error, term()}
  def inet_credentials(socket) do
    case :os.type() do
      {:unix, :linux} ->
        case :inet.getopts(socket, [{:raw, 1, 17, 12}]) do
          {:ok, [{:raw, 1, 17, bytes}]} -> decode_linux_credentials(bytes)
          {:ok, _} -> {:error, :invalid_peer_credential}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :unsupported_peer_identity}
    end
  end

  @doc """
  Validates the Linux native `struct ucred` layout returned by an OS adapter.

  This pure decoder is shared by the native and inet socket adapters. Callers
  must obtain the bytes from the actual kernel socket option; accepting a valid
  arbitrary binary from JSON or a file cannot establish connection identity.
  """
  @spec decode_linux_credentials(binary()) ::
          {:ok, %{pid: pos_integer(), uid: non_neg_integer(), gid: non_neg_integer()}}
          | {:error, :invalid_peer_credential}
  def decode_linux_credentials(
        <<pid::native-signed-integer-size(32), uid::native-unsigned-integer-size(32),
          gid::native-unsigned-integer-size(32)>>
      )
      when pid > 0 and account_id?(uid) and account_id?(gid),
      do: {:ok, %{pid: pid, uid: uid, gid: gid}}

  def decode_linux_credentials(_), do: {:error, :invalid_peer_credential}

  defp darwin_uid(socket) do
    case :socket.getopt_native(socket, {0, 1}, 80) do
      {:ok,
       <<0::native-unsigned-integer-size(32), uid::native-unsigned-integer-size(32), _::binary>>} ->
        {:ok, uid}

      {:ok, _} ->
        {:error, :invalid_peer_credential}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp linux_uid(socket) do
    case linux_credentials(socket) do
      {:ok, %{uid: uid}} -> {:ok, uid}
      error -> error
    end
  end

  defp linux_credentials(socket) do
    case :socket.getopt(socket, :socket, :peercred) do
      {:ok, %{pid: pid, uid: uid, gid: gid}}
      when is_integer(pid) and pid > 0 and account_id?(uid) and account_id?(gid) ->
        {:ok, %{pid: pid, uid: uid, gid: gid}}

      _ ->
        linux_native_credentials(socket)
    end
  end

  defp linux_native_credentials(socket) do
    case :socket.getopt_native(socket, {1, 17}, 12) do
      {:ok, bytes} ->
        decode_linux_credentials(bytes)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
