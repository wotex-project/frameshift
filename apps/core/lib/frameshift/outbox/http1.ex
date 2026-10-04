defmodule Frameshift.Outbox.HTTP1 do
  @moduledoc """
  Parses one strict finite HTTP/1.1 exchange for the pull outbox.

  `decode/1` consumes origin-form GET/POST requests with exact content lengths,
  single header values and bounded ASCII fields. It returns a complete request,
  `:more` for an incomplete bounded buffer, or an input/size error. The parser
  rejects transfer coding, pipelining, ambiguous lengths and control characters.

  ## Feeding and dispatch

  A TLS worker may accumulate records only up to `maximum_wire_bytes/0` and its
  absolute request deadline. Both header and body ceilings are 64 KiB; target and
  header counts/values have separate limits. Framing completes before any library
  access or request dispatch.

  `exchange/3` joins a complete parsed request to
  `Frameshift.Outbox.Endpoint` using the listener's verified peer certificate.
  The parser authenticates no peer and performs no network I/O; callers cannot
  replace that certificate with request-body identity.
  """

  @maximum_header_bytes 64 * 1024
  @maximum_body_bytes 64 * 1024
  @maximum_target_bytes 1_024
  @maximum_header_count 64
  @maximum_header_value_bytes 8 * 1024
  @maximum_wire_bytes @maximum_header_bytes + @maximum_body_bytes
  @digit_pattern ~r/^[0-9]+$/

  @type request :: %{
          method: String.t(),
          path: String.t(),
          content_type: String.t() | nil,
          body: binary()
        }
  @type reason :: :invalid_request | :request_too_large

  alias Frameshift.Outbox.Endpoint
  alias Frameshift.Protocol.JSON

  @doc "Returns the largest complete request the reference outbox binding will admit."
  @spec maximum_wire_bytes() :: pos_integer()
  def maximum_wire_bytes, do: @maximum_wire_bytes

  @doc "Decodes exactly one request, or asks for more bytes without allocating its body."
  @spec decode(binary()) :: {:ok, request()} | :more | {:error, reason()}
  def decode(wire) when is_binary(wire) and byte_size(wire) <= @maximum_wire_bytes do
    case :binary.match(wire, "\r\n\r\n") do
      :nomatch ->
        if byte_size(wire) <= @maximum_header_bytes,
          do: :more,
          else: {:error, :request_too_large}

      {offset, 4} when offset + 4 <= @maximum_header_bytes ->
        head = binary_part(wire, 0, offset)
        body = binary_part(wire, offset + 4, byte_size(wire) - offset - 4)
        decode_complete(head, body)

      {_, 4} ->
        {:error, :request_too_large}
    end
  end

  def decode(_), do: {:error, :request_too_large}

  @doc "Runs one complete request through certificate-scoped outbox semantics."
  @spec exchange(GenServer.server(), binary(), binary()) :: {:ok, binary()} | :more
  def exchange(library, peer_certificate_der, wire) do
    started = System.monotonic_time(:millisecond)

    case decode(wire) do
      {:ok, request} ->
        response = dispatch(request, library, peer_certificate_der)
        emit_exchange(route_name(request), response.status, started)
        encode_response(response)

      :more ->
        :more

      {:error, reason} ->
        response = problem_response(reason)
        emit_exchange(:invalid, response.status, started)
        encode_response(response)
    end
  end

  defp route_name(%{method: "GET", path: "/v0/outbox/manifest"}), do: :manifest
  defp route_name(%{method: "POST", path: "/v0/outbox/ack"}), do: :ack

  defp route_name(%{method: "GET", path: "/v0/outbox/assets/sha256/" <> _}),
    do: :asset

  defp route_name(%{method: "GET", path: "/v0/outbox/playlists/sha256/" <> _}),
    do: :playlist

  defp route_name(_), do: :invalid

  defp emit_exchange(route, status, started) do
    outcome =
      case status do
        200 -> :succeeded
        204 -> :empty
        409 -> :conflict
        503 -> :unavailable
        _ -> :rejected
      end

    :telemetry.execute(
      [:frameshift, :outbox, :exchange],
      %{count: 1, duration_ms: max(0, System.monotonic_time(:millisecond) - started)},
      %{route: route, outcome: outcome}
    )
  end

  defp dispatch(request, library, peer_certificate_der) do
    case Endpoint.handle(
           library,
           peer_certificate_der,
           request.method,
           request.path,
           request.content_type,
           request.body
         ) do
      {:ok, response} -> response
      {:error, reason} -> problem_response(reason)
    end
  end

  defp problem_response(reason) do
    {status, code, title} = problem_details(reason)

    {:ok, body} =
      JSON.encode(%{
        "type" => "urn:frameshift:problem:#{code}",
        "title" => title,
        "status" => status
      })

    %{
      status: status,
      headers: %{"content-type" => "application/problem+json"},
      body: body
    }
  end

  defp problem_details(:request_too_large), do: {413, "request-too-large", "Request too large"}

  defp problem_details(:frame_not_paired),
    do: {403, "authentication-required", "Frame not paired"}

  defp problem_details(:ambiguous_frame_identity),
    do: {403, "authentication-required", "Frame not paired"}

  defp problem_details(:invalid_peer_certificate),
    do: {403, "authentication-required", "Frame not paired"}

  defp problem_details(:pull_not_supported),
    do: {403, "unsupported-protocol", "Pull not supported"}

  defp problem_details(:not_found), do: {404, "asset-missing", "Asset not found"}

  defp problem_details(:acknowledgement_conflict),
    do: {409, "state-precondition", "Outbox changed"}

  defp problem_details(:invalid_acknowledgement),
    do: {422, "invalid-acknowledgement", "Invalid acknowledgement"}

  defp problem_details(:artifact_unavailable), do: {503, "asset-missing", "Asset unavailable"}
  defp problem_details(_), do: {400, "invalid-request", "Invalid request"}

  defp encode_response(%{status: status, headers: headers, body: body}) do
    headers =
      headers
      |> Map.merge(%{
        "cache-control" => "no-store",
        "connection" => "close",
        "content-length" => Integer.to_string(byte_size(body)),
        "x-content-type-options" => "nosniff"
      })
      |> Enum.sort()
      |> Enum.map(fn {name, value} -> [name, ": ", value, "\r\n"] end)

    {:ok,
     IO.iodata_to_binary([
       "HTTP/1.1 ",
       Integer.to_string(status),
       " ",
       status_title(status),
       "\r\n",
       headers,
       "\r\n",
       body
     ])}
  end

  defp status_title(200), do: "OK"
  defp status_title(204), do: "No Content"
  defp status_title(400), do: "Bad Request"
  defp status_title(403), do: "Forbidden"
  defp status_title(404), do: "Not Found"
  defp status_title(409), do: "Conflict"
  defp status_title(413), do: "Content Too Large"
  defp status_title(422), do: "Unprocessable Content"
  defp status_title(503), do: "Service Unavailable"

  defp decode_complete(head, body) do
    with {:ok, method, path, headers} <- decode_head(head),
         {:ok, expected_length} <- body_length(method, headers),
         :ok <- validate_body_size(body, expected_length) do
      if byte_size(body) == expected_length do
        {:ok,
         %{
           method: method,
           path: path,
           content_type: Map.get(headers, "content-type"),
           body: body
         }}
      else
        :more
      end
    end
  end

  defp decode_head(head) do
    case :binary.split(head, "\r\n", [:global]) do
      [request_line | header_lines] when length(header_lines) <= @maximum_header_count ->
        with {:ok, method, path} <- decode_request_line(request_line),
             {:ok, headers} <- decode_headers(header_lines),
             :ok <- validate_headers(headers) do
          {:ok, method, path, headers}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp decode_request_line(line) do
    case :binary.split(line, " ", [:global]) do
      [method, path, "HTTP/1.1"] when method in ["GET", "POST"] ->
        if valid_path?(path), do: {:ok, method, path}, else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp valid_path?(<<"/", _::binary>> = path)
       when byte_size(path) <= @maximum_target_bytes do
    path
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in 33..126 and &1 not in [?\#, ??]))
  end

  defp valid_path?(_), do: false

  defp decode_headers(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, &put_header/2)
  end

  defp put_header(line, {:ok, headers}) do
    case :binary.split(line, ":") do
      [name, value] -> add_header(headers, name, value)
      _ -> {:halt, {:error, :invalid_request}}
    end
  end

  defp add_header(headers, name, value) do
    if valid_header?(name, value) do
      lower_name = String.downcase(name)

      if Map.has_key?(headers, lower_name) do
        {:halt, {:error, :invalid_request}}
      else
        {:cont, {:ok, Map.put(headers, lower_name, String.trim(value, " "))}}
      end
    else
      {:halt, {:error, :invalid_request}}
    end
  end

  defp valid_header?(name, value) do
    byte_size(name) in 1..128 and
      Enum.all?(:binary.bin_to_list(name), &header_name_byte?/1) and
      byte_size(value) <= @maximum_header_value_bytes and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 32..126))
  end

  defp header_name_byte?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte == ?-

  defp validate_headers(headers) do
    if Map.get(headers, "host", "") != "" and
         not Enum.any?(["transfer-encoding", "expect", "upgrade"], &Map.has_key?(headers, &1)) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp body_length("GET", headers) do
    case Map.get(headers, "content-length") do
      nil -> {:ok, 0}
      "0" -> {:ok, 0}
      _ -> {:error, :invalid_request}
    end
  end

  defp body_length("POST", %{"content-type" => "application/json"} = headers) do
    case Map.get(headers, "content-length") do
      value when is_binary(value) -> decode_length(value)
      nil -> {:error, :invalid_request}
    end
  end

  defp body_length("POST", _), do: {:error, :invalid_request}

  defp decode_length(value) when byte_size(value) in 1..6 do
    if Regex.match?(@digit_pattern, value) do
      length = String.to_integer(value)

      cond do
        Integer.to_string(length) != value -> {:error, :invalid_request}
        length > @maximum_body_bytes -> {:error, :request_too_large}
        true -> {:ok, length}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp decode_length(_), do: {:error, :request_too_large}

  defp validate_body_size(body, expected_length) when byte_size(body) <= expected_length, do: :ok
  defp validate_body_size(_, _), do: {:error, :invalid_request}
end
