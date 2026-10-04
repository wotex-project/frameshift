defmodule Frameshift.Pairing.HTTP1 do
  @moduledoc """
  Dispatches the fixed pairing and authenticated TD routes over strict HTTP/1.1.

  `exchange/4` uses the shared `Frameshift.Outbox.HTTP1` parser with tighter
  pairing wire/body limits. It returns more-data, refusal or one finite response
  for the fixed commissioning route or authenticated TD read, using the TLS
  listener's peer DER and explicit time.

  ## Authority and persistence

  Headers and JSON cannot choose the peer certificate. Pair mode is opened only
  through the frame's physical adapter; network traffic can merely attempt the
  already-open window. The simulator owner persists authorization before the
  success response is released.

  `maximum_wire_bytes/0` exposes the pairing exchange ceiling so a reader can
  bound accumulation before dispatch. This reference binding is not evidence of
  real firmware key protection, flash durability or a physical input mechanism.
  """

  alias Frameshift.Outbox.HTTP1, as: RequestParser
  alias Frameshift.Simulator

  @path "/.well-known/frameshift/pair"
  @thing_path "/.well-known/wot"
  @maximum_wire_bytes 8_192
  @maximum_body_bytes 2_048

  @doc "Returns the pairing binding's maximum complete wire request size."
  @spec maximum_wire_bytes() :: pos_integer()
  def maximum_wire_bytes, do: @maximum_wire_bytes

  @doc "Consumes one complete request or asks the TLS reader for more bytes."
  @spec exchange(GenServer.server(), binary(), binary(), non_neg_integer()) ::
          {:ok, binary()} | :more
  def exchange(_, _, wire, _) when byte_size(wire) > @maximum_wire_bytes,
    do: error(413, "request-too-large", "Request too large")

  def exchange(frame, peer_der, wire, now_ms),
    do: respond(RequestParser.decode(wire), frame, peer_der, now_ms, byte_size(wire))

  defp respond(
         {:ok, %{method: "GET", path: @thing_path, body: <<>>}},
         frame,
         peer_der,
         _,
         _
       ) do
    case Simulator.authorized_thing(frame, peer_der) do
      {:ok, source} ->
        {:ok, encode(%{status: 200, content_type: "application/json", body: source})}

      {:error, _} ->
        error(404, "not-found", "Resource not found")
    end
  end

  defp respond(
         {:ok, %{method: "POST", path: @path, content_type: "application/json", body: body}},
         frame,
         peer_der,
         now_ms,
         _
       )
       when byte_size(body) <= @maximum_body_bytes do
    case Simulator.pair(frame, peer_der, body, now_ms) do
      {:ok, response} -> {:ok, encode(response)}
      {:error, _} -> error(503, "pairing-unavailable", "Pairing unavailable")
    end
  end

  defp respond({:ok, %{body: body}}, _, _, _, _)
       when byte_size(body) > @maximum_body_bytes,
       do: error(413, "request-too-large", "Request too large")

  defp respond({:ok, _}, _, _, _, _),
    do: error(404, "not-found", "Resource not found")

  defp respond({:error, :request_too_large}, _, _, _, _),
    do: error(413, "request-too-large", "Request too large")

  defp respond({:error, _}, _, _, _, _),
    do: error(400, "invalid-request", "Invalid request")

  defp respond(:more, _, _, _, wire_size) do
    if wire_size < @maximum_wire_bytes,
      do: :more,
      else: error(413, "request-too-large", "Request too large")
  end

  defp error(status, code, title) do
    body =
      RFC8785.encode!(%{
        "type" => "urn:frameshift:problem:#{code}",
        "title" => title,
        "status" => status
      })

    {:ok, encode(%{status: status, content_type: "application/problem+json", body: body})}
  end

  defp encode(%{status: status, content_type: content_type, body: body}) do
    IO.iodata_to_binary([
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      status_title(status),
      "\r\n",
      "cache-control: no-store\r\n",
      "connection: close\r\n",
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "content-type: ",
      content_type,
      "\r\n",
      "x-content-type-options: nosniff\r\n",
      "\r\n",
      body
    ])
  end

  defp status_title(200), do: "OK"
  defp status_title(201), do: "Created"
  defp status_title(400), do: "Bad Request"
  defp status_title(403), do: "Forbidden"
  defp status_title(404), do: "Not Found"
  defp status_title(409), do: "Conflict"
  defp status_title(413), do: "Content Too Large"
  defp status_title(429), do: "Too Many Requests"
  defp status_title(503), do: "Service Unavailable"
end
