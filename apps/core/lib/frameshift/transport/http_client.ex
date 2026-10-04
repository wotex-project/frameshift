defmodule Frameshift.Transport.HTTPClient do
  @moduledoc """
  Performs one finite authenticated HTTPS exchange for the Wotex binding.

  `request/3` accepts a typed binding request, ephemeral
  `Frameshift.Transport.MTLSCredential` and explicit configuration. It checks the
  exact credential audience, all resolved addresses, header/body bounds and the
  remaining absolute deadline before connecting. Mutual TLS verifies the pinned
  frame key; redirects and connection pooling are refused.

  ## Network and lifecycle limits

  `Frameshift.Transport.SystemResolver` is the default DNS resolver. Local-network
  address policy applies to every result, with loopback disabled by default and
  only explicitly enabled in the configured scope. Each connection closes after
  its bounded response; credentials do not enter a shared pool or redirect target.

  The client supports finite Property/Action requests, not an SSE subscription
  lifecycle. Subscription/close callbacks return explicit unsupported/unknown
  outcomes. Failures remain transport errors: a successful HTTP reply does not
  establish that desired artwork is physically displayed. Delivery callers must
  reconcile state through the advertised interaction.
  """

  @behaviour Wotex.Binding.HTTP.Client

  alias Frameshift.Transport.{MTLSCredential, SPKIPin, SystemResolver}
  alias Wotex.Binding.HTTP.{Headers, Request, Response}
  alias Wotex.Runtime.Context

  @default_config %{
    resolver: {SystemResolver, nil},
    allow_loopback: false,
    tls_versions: [:"tlsv1.3", :"tlsv1.2"]
  }
  @status_line_allowance 512
  @header_wire_allowance 4
  @maximum_header_value_bytes 8 * 1024

  @impl Wotex.Binding.HTTP.Client
  def request(%Request{} = request, %MTLSCredential{} = credential, config)
      when is_map(config) do
    config = Map.merge(@default_config, config)

    with :ok <- validate_header_value_sizes(Request.headers(request)),
         {:ok, uri} <- authorize_target(Request.uri(request), credential),
         {:ok, timeout} <- remaining_timeout(Request.deadline(request)),
         {:ok, addresses} <- resolve_addresses(uri.host, config),
         :ok <- authorize_addresses(addresses, config),
         {:ok, connection} <- connect(addresses, uri, credential, request, timeout, config) do
      execute(connection, uri, request)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  rescue
    _ -> {:error, :transport_failure}
  catch
    _, _ -> {:error, :transport_failure}
  end

  def request(_, _, _), do: {:error, :invalid_client_arguments}

  @impl Wotex.Binding.HTTP.Client
  def subscribe(_, _, _, _),
    do: {:error, :streaming_not_available}

  @impl Wotex.Binding.HTTP.Client
  def close(_, _), do: {:error, :unknown_subscription}

  defp authorize_target(target, credential) do
    with {:ok, uri} <- URI.new(target),
         true <- uri.scheme == "https",
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         port when port in 1..65_535 <- uri.port || 443,
         true <- String.downcase(uri.host) == credential.host and port == credential.port do
      {:ok, %{uri | port: port}}
    else
      _ -> {:error, :credential_audience_mismatch}
    end
  end

  defp remaining_timeout(deadline) when is_integer(deadline) do
    normalize_timeout(Context.remaining_ms(deadline, System.monotonic_time(:millisecond)))
  end

  defp remaining_timeout(%DateTime{} = deadline) do
    normalize_timeout(Context.remaining_ms(deadline, DateTime.utc_now()))
  end

  defp remaining_timeout(_), do: {:error, :deadline_required}

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_timeout(_), do: {:error, :timeout}

  defp resolve_addresses(host, %{resolver: {module, resolver_config}}) when is_atom(module) do
    case module.resolve(host, resolver_config) do
      {:ok, [_ | _] = addresses} -> {:ok, Enum.uniq(addresses)}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :resolver_contract_violation}
    end
  end

  defp resolve_addresses(_, _), do: {:error, :invalid_resolver}

  defp authorize_addresses(addresses, config) do
    if Enum.all?(addresses, &local_address?(&1, config.allow_loopback)),
      do: :ok,
      else: {:error, :destination_forbidden}
  end

  defp local_address?({10, _, _, _}, _), do: true
  defp local_address?({172, second, _, _}, _) when second in 16..31, do: true
  defp local_address?({192, 168, _, _}, _), do: true
  defp local_address?({169, 254, _, _}, _), do: true
  defp local_address?({127, _, _, _}, true), do: true
  defp local_address?({0, 0, 0, 0, 0, 0, 0, 1}, true), do: true

  defp local_address?({first, _, _, _, _, _, _, _}, _)
       when Bitwise.band(first, 0xFE00) == 0xFC00,
       do: true

  defp local_address?({0xFE80, _, _, _, _, _, _, _}, _), do: true

  defp local_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}, allow_loopback) do
    local_address?(
      {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8),
       Bitwise.band(low, 0xFF)},
      allow_loopback
    )
  end

  defp local_address?(_, _), do: false

  defp connect(addresses, uri, credential, request, timeout, config) do
    options = [
      hostname: uri.host,
      protocols: [:http1],
      mode: :passive,
      max_header_list_size: header_wire_limit(request),
      transport_opts: [
        verify: :verify_peer,
        cacerts: [],
        cert: credential.client_certificate,
        key: credential.client_private_key,
        versions: config.tls_versions,
        timeout: timeout,
        verify_fun: {&SPKIPin.verify/3, %{expected: credential.server_spki_sha256}}
      ]
    ]

    connect_next(addresses, uri.port, options, Request.deadline(request))
  end

  defp connect_next([], _, _, _), do: {:error, :connection_failed}

  defp connect_next([address | rest], port, options, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline) do
      updated_options =
        update_in(options, [:transport_opts], &Keyword.put(&1, :timeout, timeout))

      case Mint.HTTP.connect(:https, address, port, updated_options) do
        {:ok, connection} -> {:ok, connection}
        {:error, _} -> connect_next(rest, port, options, deadline)
      end
    end
  end

  defp execute(connection, uri, request) do
    path = request_path(uri)
    body = Request.body(request)

    case Mint.HTTP.request(
           connection,
           Request.method(request),
           path,
           Request.headers(request),
           body
         ) do
      {:ok, connection, reference} ->
        receive_response(connection, reference, request, empty_response())

      {:error, _, _} ->
        {:error, :request_failed}
    end
  after
    Mint.HTTP.close(connection)
  end

  defp receive_response(connection, reference, request, response) do
    with {:ok, timeout} <- remaining_timeout(Request.deadline(request)) do
      case Mint.HTTP.recv(connection, 0, timeout) do
        {:ok, next_connection, parts} ->
          handle_parts(parts, next_connection, reference, request, response)

        {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
          {:error, :timeout}

        {:error, _, _, _} ->
          {:error, :response_failed}
      end
    end
  end

  defp handle_parts(parts, connection, reference, request, response) do
    case consume_parts(parts, reference, request, response) do
      {:continue, next_response} ->
        receive_response(connection, reference, request, next_response)

      {:done, complete} ->
        build_response(complete, request)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_response,
    do: %{status: nil, headers: nil, body: [], body_bytes: 0, done?: false}

  defp consume_parts(parts, reference, request, response) do
    Enum.reduce_while(parts, {:continue, response}, fn part, {:continue, accumulator} ->
      case consume_part(part, reference, request, accumulator) do
        {:continue, next} -> {:cont, {:continue, next}}
        {:done, next} -> {:halt, {:done, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp consume_part({:status, reference, status}, reference, _, %{status: nil} = response)
       when status in 100..599,
       do: {:continue, %{response | status: status}}

  defp consume_part({:headers, reference, headers}, reference, request, response)
       when is_list(headers) and is_nil(response.headers) do
    with :ok <- validate_headers(headers, request),
         :ok <- validate_content_length(headers, Request.max_response_bytes(request)) do
      {:continue, %{response | headers: headers}}
    end
  end

  defp consume_part({:data, reference, data}, reference, request, response)
       when is_binary(data) do
    body_bytes = response.body_bytes + byte_size(data)

    if body_bytes <= Request.max_response_bytes(request) do
      {:continue, %{response | body: [data | response.body], body_bytes: body_bytes}}
    else
      {:error, :response_too_large}
    end
  end

  defp consume_part({:done, reference}, reference, _, response) do
    if is_integer(response.status) and is_list(response.headers),
      do: {:done, %{response | done?: true}},
      else: {:error, :incomplete_response}
  end

  defp consume_part({:error, reference, _}, reference, _, _),
    do: {:error, :response_failed}

  defp consume_part({_, other_reference, _}, reference, _, response)
       when other_reference != reference,
       do: {:continue, response}

  defp consume_part(_, _, _, _),
    do: {:error, :response_contract_violation}

  defp validate_headers(headers, request) do
    with {:ok, normalized} <- Headers.new(headers, :response),
         :ok <- validate_header_value_sizes(normalized),
         :ok <-
           Headers.validate_limits(
             normalized,
             Request.max_header_count(request),
             Request.max_header_bytes(request),
             :response
           ) do
      :ok
    else
      {:error, _} -> {:error, :invalid_response_headers}
    end
  end

  defp validate_header_value_sizes(headers) do
    if Enum.all?(headers, fn {_, value} ->
         byte_size(value) <= @maximum_header_value_bytes
       end) do
      :ok
    else
      {:error, :header_value_too_large}
    end
  end

  defp validate_content_length(headers, maximum) do
    values =
      for {name, value} <- headers,
          String.downcase(name) == "content-length",
          do: value

    case values do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 and length <= maximum -> :ok
          {length, ""} when length > maximum -> {:error, :response_too_large}
          _ -> {:error, :invalid_content_length}
        end

      _ ->
        {:error, :invalid_content_length}
    end
  end

  defp build_response(%{status: status, headers: headers, body: body, done?: true}, _) do
    case Response.new(status, headers, body |> Enum.reverse() |> IO.iodata_to_binary()) do
      {:ok, response} -> {:ok, response}
      {:error, _} -> {:error, :invalid_response}
    end
  end

  defp request_path(%URI{path: path, query: query}) do
    base = if path in [nil, ""], do: "/", else: path
    if is_binary(query), do: "#{base}?#{query}", else: base
  end

  defp header_wire_limit(request) do
    Request.max_header_bytes(request) +
      Request.max_header_count(request) * @header_wire_allowance + @status_line_allowance
  end
end
