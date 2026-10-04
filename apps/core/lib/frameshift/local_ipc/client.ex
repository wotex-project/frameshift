defmodule Frameshift.LocalIPC.Client do
  @moduledoc """
  Exchanges one bounded request with a verified Linux service socket.

  `exchange/5` receives a request map, endpoint role, expected service UID and
  group GID from the caller's admitted local policy. It checks the final socket
  and parent inode, connects, and compares actual kernel peer UID before sending
  anything. Directory ownership alone cannot identify the running server. It
  neither creates paths nor starts services, reads cookies or falls back to TCP.

  ## Framing and outcomes

  Command frames are bounded to 64 KiB requests and 1 MiB responses; diagnostic
  frames to 8 KiB and 256 KiB. Connection/send waits are finite and one packet
  receive has an absolute deadline of at most thirty seconds. JSON admission
  rejects hostile structure and duplicate members before envelope validation.
  Responses must match the version and request identity. A malformed or missing
  response after a mutation send attempt returns `:command_outcome_unknown`;
  the caller retains its original command ID and must not automatically replay.

  The optional response deadline can only shorten the production ceiling. This
  supports bounded callers and timeout fixtures, not a wire-controlled setting.
  Final inode checks do not establish ancestor race protection or installed
  policy custody; package qualification owns those filesystem guarantees.
  """

  alias Frameshift.LocalIPC.PeerIdentity
  alias Frameshift.LocalIPC.SocketDirectory

  @doc "Sends one verified group request and returns a validated envelope or finite refusal."
  @spec exchange(String.t(), map(), :command | :diagnostics, keyword(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def exchange(path, request, role, policy, timeout_ms \\ 30_000)

  def exchange(path, request, role, policy, timeout_ms)
      when role in [:command, :diagnostics] and timeout_ms in 1..30_000 do
    {maximum_request, maximum_response} = limits(role)

    with {:ok, payload} <- RFC8785.encode(request),
         true <- byte_size(payload) <= maximum_request,
         :ok <- SocketDirectory.validate_group_socket(path, policy[:gid], policy[:uid]),
         {:ok, socket} <- connect(path, maximum_response) do
      try do
        exchange_connected(socket, path, request, payload, role, policy, timeout_ms)
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def exchange(_, _, _, _, _), do: {:error, :unavailable}

  defp connect(path, maximum_response) do
    :gen_tcp.connect(
      {:local, path},
      0,
      [
        :binary,
        packet: 4,
        packet_size: maximum_response,
        active: false,
        send_timeout: 5_000,
        send_timeout_close: true
      ],
      1_000
    )
  end

  defp exchange_connected(socket, path, request, payload, role, policy, timeout_ms) do
    with {:ok, %{uid: uid}} <- PeerIdentity.inet_credentials(socket),
         true <- uid == policy[:uid] and uid > 0,
         :ok <- SocketDirectory.validate_group_socket(path, policy[:gid], uid) do
      sent_exchange(socket, request, payload, role, timeout_ms)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp sent_exchange(socket, request, payload, role, timeout_ms) do
    with :ok <- :gen_tcp.send(socket, payload),
         {:ok, response} <- :gen_tcp.recv(socket, 0, timeout_ms),
         {:ok, envelope} <- decode(response, role),
         :ok <- validate_envelope(envelope, request, role),
         {:ok, _} <- RFC8785.encode(envelope) do
      {:ok, envelope}
    else
      _ -> {:error, uncertain_code(request)}
    end
  rescue
    _ -> {:error, uncertain_code(request)}
  catch
    _, _ -> {:error, uncertain_code(request)}
  end

  defp decode(bytes, role) do
    {_, maximum_response} = limits(role)

    Wotex.JSON.decode(bytes,
      max_bytes: maximum_response,
      max_depth: 16,
      max_nodes: 20_000,
      max_string_bytes: 8_192,
      max_collection_size: 512
    )
  end

  defp validate_envelope(
         %{"version" => 1, "requestId" => id, "ok" => true} = response,
         request,
         role
       ) do
    key = if role == :diagnostics, do: "diagnostics", else: response_key(request["operation"])

    if id == request["requestId"] and valid_payload?(key, response[key], request) and
         Map.keys(response) -- ["version", "requestId", "ok", key] == [],
       do: :ok,
       else: {:error, :invalid_response}
  end

  defp validate_envelope(
         %{"version" => 1, "requestId" => id, "ok" => false, "error" => %{"code" => code} = error} =
           response,
         request,
         _
       ) do
    if id == request["requestId"] and Map.keys(error) == ["code"] and
         Map.keys(response) -- ~w(version requestId ok error) == [] and is_binary(code) and
         String.match?(code, ~r/\A[a-z0-9_]{1,64}\z/), do: :ok, else: {:error, :invalid_response}
  end

  defp validate_envelope(_, _, _), do: {:error, :invalid_response}

  defp valid_payload?("frame", %{"frameId" => id} = frame, request),
    do:
      map_size(frame) == 1 and is_binary(id) and byte_size(id) in 16..128 and
        id == request["discoveredId"]

  defp valid_payload?("frame", _, _), do: false
  defp valid_payload?(_, value, _), do: is_map(value)

  defp response_key("command"), do: "snapshot"
  defp response_key("snapshot"), do: "snapshot"
  defp response_key("libraryMetadata"), do: "metadata"
  defp response_key("libraryRecovery"), do: "recovery"
  defp response_key("libraryStorage"), do: "storage"
  defp response_key(operation) when operation in ["pair", "recoverPair"], do: "frame"
  defp response_key(_), do: nil

  defp uncertain_code(%{"operation" => operation})
       when operation in ["command", "pair", "recoverPair"],
       do: :command_outcome_unknown

  defp uncertain_code(_), do: :unavailable
  defp limits(:command), do: {64 * 1024, 1024 * 1024}
  defp limits(:diagnostics), do: {8_192, 256 * 1024}
end
