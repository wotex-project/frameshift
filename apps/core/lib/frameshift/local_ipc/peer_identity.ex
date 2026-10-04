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
  `Frameshift.LocalIPC.DiagnosticsServer` uses the UID boundary for read-only access.

  Peer identity proves the local connection's OS credential, not the application's
  role, launch token or payload validity. Protocol parsing and any additional
  command authorization remain the consuming server's responsibility.
  """

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
      when is_integer(pid) and pid > 0 and is_integer(uid) and uid >= 0 and
             is_integer(gid) and gid >= 0 ->
        {:ok, %{pid: pid, uid: uid, gid: gid}}

      _ ->
        linux_native_credentials(socket)
    end
  end

  defp linux_native_credentials(socket) do
    case :socket.getopt_native(socket, {1, 17}, 12) do
      {:ok,
       <<pid::native-signed-integer-size(32), uid::native-unsigned-integer-size(32),
         gid::native-unsigned-integer-size(32)>>}
      when pid > 0 ->
        {:ok, %{pid: pid, uid: uid, gid: gid}}

      {:ok, _} ->
        {:error, :invalid_peer_credential}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
