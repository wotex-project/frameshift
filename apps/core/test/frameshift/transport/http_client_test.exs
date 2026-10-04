defmodule Frameshift.Transport.HTTPClientTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Digest
  alias Frameshift.DirectSync
  alias Frameshift.DirectSync.Artifact
  alias Frameshift.Protocol.Thing
  alias Frameshift.Transport.{HTTPClient, MTLSCredential, SPKIPin}
  alias Wotex.Binding.HTTP, as: WotexHTTP
  alias Wotex.Binding.HTTP.{Request, Response}
  alias Wotex.Runtime.{ConsumedThing, Context}
  alias Wotex.ThingDescription

  defmodule StaticCredentials do
    @moduledoc false

    @behaviour Wotex.Runtime.Credentials

    @impl Wotex.Runtime.Credentials
    def resolve(_, _, _, credential), do: {:ok, credential}
  end

  defmodule FixtureResolver do
    @moduledoc false

    @spec resolve(term(), term()) :: term()
    def resolve(_, result), do: result
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)

    subject_alt_name = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    key = {:rsa, 2048, 65_537}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: key],
          intermediates: [],
          peer: [key: key, extensions: [subject_alt_name]]
        },
        client_chain: %{root: [key: key], intermediates: [], peer: [key: key]}
      })

    certificate = Keyword.fetch!(data.server_config, :cert)
    decoded = :public_key.pkix_decode_cert(certificate, :otp)
    {:ok, fingerprint} = SPKIPin.fingerprint(decoded)

    {:ok,
     %{
       server: data.server_config,
       client: data.client_config,
       decoded_server_certificate: decoded,
       fingerprint: "sha256:" <> Base.encode16(fingerprint, case: :lower)
     }}
  end

  test "executes a bounded one-shot request over mutual TLS and a pinned server identity", pki do
    %{url: url, request: received} =
      serve_once(pki.server, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n42")

    request = request(url, max_response_bytes: 2)
    credential = credential(pki, origin(url))

    assert {:ok, response} = HTTPClient.request(request, credential, %{allow_loopback: true})
    assert Response.status(response) == 200
    assert Response.body(response) == "42"
    assert_receive {^received, bytes}
    assert bytes =~ "GET /state HTTP/1.1"
  end

  test "executes a pinned mutually authenticated request on literal IPv6 loopback", pki do
    server = Keyword.put(pki.server, :ip, {0, 0, 0, 0, 0, 0, 0, 1})

    %{url: listener_url, request: received} =
      serve_once([:inet6 | server], "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n42")

    port = URI.new!(listener_url).port
    origin = "https://[::1]:#{port}"
    credential = credential(pki, origin)
    assert credential.origin == origin

    assert {:ok, response} =
             HTTPClient.request(request(origin <> "/state"), credential, %{allow_loopback: true})

    assert Response.body(response) == "42"
    assert_receive {^received, bytes}
    assert bytes =~ "GET /state HTTP/1.1"
    assert bytes =~ "[::1]:#{port}"
  end

  test "executes a selected TD Property through the pinned Wotex binding", pki do
    body = ~s({"displayState":"displayed","stateRevision":7})

    %{url: url, request: received} =
      serve_once(
        pki.server,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"
      )

    {:ok, td} =
      ThingDescription.from_map(%{
        "@context" => Wotex.td_context_1_1(),
        "id" => "urn:frameshift:test:transport",
        "title" => "Transport test frame",
        "base" => origin(url) <> "/",
        "securityDefinitions" => %{
          "mtls" => %{"scheme" => "auto", "frameshift:mechanism" => "mutual-tls"}
        },
        "security" => ["mtls"],
        "properties" => %{
          "state" => %{
            "type" => "object",
            "readOnly" => true,
            "forms" => [
              %{
                "href" => "state",
                "contentType" => "application/json",
                "op" => "readproperty"
              }
            ]
          }
        }
      })

    {:ok, profile} = WotexHTTP.profile()

    {:ok, binding_config} =
      WotexHTTP.config(
        client: {HTTPClient, %{allow_loopback: true}},
        max_response_bytes: 4_096,
        max_header_count: 16,
        max_header_bytes: 4_096,
        max_uri_bytes: 1_024
      )

    {:ok, consumed} =
      ConsumedThing.new(td,
        profiles: [profile],
        transports: %{http: WotexHTTP.transport(binding_config)},
        credentials: {StaticCredentials, credential(pki, origin(url))}
      )

    context =
      Context.new!(
        request_id: "selected-property-test",
        deadline: System.monotonic_time(:millisecond) + 5_000
      )

    assert {:ok, result} = ConsumedThing.read_property(consumed, "state", context)
    assert result.payload == %{"displayState" => "displayed", "stateRevision" => 7}
    assert result.metadata.http.status == 200
    assert_receive {^received, bytes}
    assert bytes =~ "GET /state HTTP/1.1"
  end

  test "runs the complete advertised binary push and state reconciliation over pinned mTLS",
       pki do
    bytes = <<1, 3, 5, 7, 9, 11>>
    digest = Digest.sha256(bytes)
    profile_id = "urn:frameshift:profile:sim-rgb24-v1"
    media_type = "application/vnd.frameshift.rgb24"
    request_id = "live-direct-sync"
    {:ok, artifact} = Artifact.new(bytes, digest, profile_id, media_type)

    empty = frame_state(0, "empty", nil, nil, nil)
    pending = frame_state(1, "refreshing", digest, nil, request_id)
    displayed = frame_state(2, "displayed", digest, digest, nil)

    server =
      serve_sequence(pki.server, [
        json_http_response(200, empty, [{"ETag", ~s("state-0")}]),
        "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n",
        json_http_response(202, pending),
        json_http_response(200, displayed, [{"ETag", ~s("state-2")}])
      ])

    document =
      "../../../../../protocol/fixtures/valid/thing-description.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> RFC8785.decode!()
      |> Map.put("base", server.origin <> "/")

    {:ok, td} = document |> RFC8785.encode!() |> Thing.parse_frame()

    {:ok, config} =
      WotexHTTP.config(
        client: {HTTPClient, %{allow_loopback: true}},
        max_request_bytes: 64 * 1024,
        max_response_bytes: 64 * 1024,
        max_event_bytes: 64 * 1024,
        max_header_count: 64,
        max_header_bytes: 64 * 8 * 1024,
        max_uri_bytes: 1_024
      )

    sync_context =
      Context.new!(
        request_id: request_id,
        deadline: System.monotonic_time(:millisecond) + 10_000
      )

    assert {:ok, %{outcome: :displayed, installation: :created}} =
             DirectSync.sync(
               td,
               artifact,
               credential(pki, server.origin),
               config,
               sync_context
             )

    requests =
      Enum.map(1..4, fn index ->
        assert_receive {reference, ^index, request_bytes} when reference == server.request
        request_bytes
      end)

    [initial_request, install_request, desired_request, final_request] = requests
    hex = Digest.hex!(digest)
    encoded_digest = bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()

    assert initial_request =~ "GET /v0/state HTTP/1.1"
    assert install_request =~ "PUT /v0/assets/sha256/#{hex} HTTP/1.1"
    assert install_request =~ "content-length: 6"
    assert install_request =~ "content-digest: sha-256=:#{encoded_digest}:"
    assert install_request =~ "frameshift-artifact-profile: #{profile_id}"
    assert install_request =~ "if-none-match: *"
    assert String.ends_with?(install_request, bytes)
    assert desired_request =~ "PUT /v0/desired HTTP/1.1"
    assert desired_request =~ "if-none-match: *"
    assert desired_request =~ request_id
    assert final_request =~ "GET /v0/state HTTP/1.1"
    assert_receive {:server_finished, reference, :ok} when reference == server.request
  end

  test "rejects a different server pin during the TLS handshake", pki do
    %{url: url} = serve_once(pki.server, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n42")

    wrong_fingerprint = "sha256:" <> String.duplicate("0", 64)
    credential = credential(pki, origin(url), wrong_fingerprint)

    assert {:error, :connection_failed} =
             HTTPClient.request(request(url), credential, %{allow_loopback: true})
  end

  test "rejects a request outside the credential authority before network I/O", pki do
    %{url: url} = serve_once(pki.server, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n42")
    credential = credential(pki, "https://different.local")

    assert {:error, :credential_audience_mismatch} =
             HTTPClient.request(request(url), credential, %{allow_loopback: true})
  end

  test "rejects non-local destinations before connecting", pki do
    credential = credential(pki, "https://8.8.8.8")

    assert {:error, :destination_forbidden} =
             HTTPClient.request(request("https://8.8.8.8/state"), credential, %{})
  end

  test "requires an absolute request deadline", pki do
    credential = credential(pki, "https://192.168.1.20")

    assert {:error, :deadline_required} =
             HTTPClient.request(
               request("https://192.168.1.20/state", deadline: nil),
               credential,
               %{}
             )
  end

  test "rejects an oversized request header value before network I/O", pki do
    credential = credential(pki, "https://192.168.1.20")

    assert {:error, :header_value_too_large} =
             HTTPClient.request(
               request("https://192.168.1.20/state",
                 headers: [{"x-large", String.duplicate("x", 8 * 1024 + 1)}],
                 max_header_bytes: 16 * 1024
               ),
               credential,
               %{}
             )
  end

  test "rejects expired deadlines, invalid resolver returns, and invalid callback arguments",
       pki do
    credential = credential(pki, "https://192.168.1.20")

    assert {:error, :timeout} =
             HTTPClient.request(
               request("https://192.168.1.20/state",
                 deadline: System.monotonic_time(:millisecond) - 1
               ),
               credential,
               %{}
             )

    assert {:error, :resolver_contract_violation} =
             HTTPClient.request(
               request("https://192.168.1.20/state"),
               credential,
               %{resolver: {FixtureResolver, :invalid}}
             )

    assert {:error, :invalid_client_arguments} = HTTPClient.request(:invalid, credential, %{})
  end

  test "rejects an oversized response from Content-Length before collecting its body", pki do
    %{url: url} =
      serve_once(
        pki.server,
        "HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n\r\n" <> String.duplicate("x", 64)
      )

    assert {:error, :response_too_large} =
             HTTPClient.request(
               request(url, max_response_bytes: 8),
               credential(pki, origin(url)),
               %{allow_loopback: true}
             )
  end

  test "credential construction is strict and inspection redacts key material", pki do
    certificate = Keyword.fetch!(pki.client, :cert)
    private_key = Keyword.fetch!(pki.client, :key)

    assert {:error, :invalid_credential_origin} =
             MTLSCredential.new(
               "http://frame.local",
               pki.fingerprint,
               certificate,
               private_key
             )

    assert {:error, :invalid_server_fingerprint} =
             MTLSCredential.new(
               "https://frame.local",
               "sha256:not-a-pin",
               certificate,
               private_key
             )

    assert {:ok, credential} =
             MTLSCredential.new(
               "https://frame.local",
               pki.fingerprint,
               certificate,
               private_key
             )

    inspected = inspect(credential)
    assert inspected =~ "credentials=redacted"
    refute inspected =~ inspect(private_key)
    refute inspected =~ Base.encode64(certificate)
  end

  test "SPKI verification accepts only the pinned peer and safe path exceptions", pki do
    certificate = pki.decoded_server_certificate
    {:ok, expected} = SPKIPin.fingerprint(certificate)
    state = %{expected: expected}

    assert {:valid, ^state} = SPKIPin.verify(certificate, {:bad_cert, :unknown_ca}, state)
    assert {:valid, ^state} = SPKIPin.verify(certificate, :valid, state)
    assert {:unknown, ^state} = SPKIPin.verify(certificate, {:extension, :unknown}, state)

    assert {:fail, {:bad_cert, :cert_expired}} =
             SPKIPin.verify(certificate, {:bad_cert, :cert_expired}, state)

    assert {:valid, %{matched: true}} = SPKIPin.verify(certificate, :valid_peer, state)

    assert {:fail, :server_spki_mismatch} =
             SPKIPin.verify(certificate, :valid_peer, %{expected: <<0::256>>})

    assert {:error, :invalid_certificate} = SPKIPin.fingerprint({})
    assert {:error, :invalid_certificate} = SPKIPin.fingerprint(:invalid)
    assert {:error, :invalid_certificate} = SPKIPin.fingerprint_der(<<1, 2, 3>>)
    assert {:error, :invalid_certificate} = SPKIPin.fingerprint_der(<<>>)
    assert {:fail, :invalid_peer_certificate} = SPKIPin.verify({}, :valid_peer, state)
    assert {:unknown, ^state} = SPKIPin.verify(certificate, :unexpected, state)
  end

  defp request(url, options \\ []) do
    deadline = Keyword.get(options, :deadline, System.monotonic_time(:millisecond) + 5_000)

    {:ok, request} =
      Request.new("GET", url, Keyword.get(options, :headers, []), nil,
        request_id: "http-client-test",
        deadline: deadline,
        operation: :readproperty,
        media_type: "application/json",
        stream?: false,
        max_response_bytes: Keyword.get(options, :max_response_bytes, 4_096),
        max_event_bytes: 4_096,
        max_header_count: 16,
        max_header_bytes: Keyword.get(options, :max_header_bytes, 4_096),
        max_uri_bytes: 1_024
      )

    request
  end

  defp credential(pki, origin, fingerprint \\ nil) do
    {:ok, credential} =
      MTLSCredential.new(
        origin,
        fingerprint || pki.fingerprint,
        Keyword.fetch!(pki.client, :cert),
        Keyword.fetch!(pki.client, :key)
      )

    credential
  end

  defp origin(url) do
    uri = URI.parse(url)
    "https://#{uri.host}:#{uri.port}"
  end

  defp serve_once(server_config, response) do
    options =
      server_config ++
        [
          active: false,
          mode: :binary,
          reuseaddr: true,
          verify: :verify_peer,
          fail_if_no_peer_cert: true
        ]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()
    request_message = make_ref()

    pid =
      spawn(fn ->
        result =
          with {:ok, transport} <- :ssl.transport_accept(listener, 5_000),
               {:ok, socket} <- :ssl.handshake(transport, 5_000),
               {:ok, request_bytes} <- receive_headers(socket, <<>>),
               :ok <- :ssl.send(socket, response) do
            send(owner, {request_message, request_bytes})
            :ssl.close(socket)
          end

        send(owner, {:server_finished, request_message, result})
        :ssl.close(listener)
      end)

    on_exit(fn ->
      :ssl.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    %{url: "https://localhost:#{port}/state", request: request_message}
  end

  defp serve_sequence(server_config, responses) do
    options =
      server_config ++
        [
          active: false,
          mode: :binary,
          reuseaddr: true,
          verify: :verify_peer,
          fail_if_no_peer_cert: true
        ]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()
    request_message = make_ref()

    pid =
      spawn(fn ->
        result = serve_responses(listener, responses, owner, request_message)

        send(owner, {:server_finished, request_message, result})
        :ssl.close(listener)
      end)

    on_exit(fn ->
      :ssl.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    %{origin: "https://localhost:#{port}", request: request_message}
  end

  defp serve_responses(listener, responses, owner, request_message) do
    responses
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {response, index}, :ok ->
      case serve_response(listener, response) do
        {:ok, request_bytes} ->
          send(owner, {request_message, index, request_bytes})
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp serve_response(listener, response) do
    with {:ok, transport} <- :ssl.transport_accept(listener, 5_000),
         {:ok, socket} <- :ssl.handshake(transport, 5_000) do
      serve_connected(socket, response)
    end
  end

  defp serve_connected(socket, response) do
    with {:ok, request_bytes} <- receive_request(socket, <<>>),
         :ok <- :ssl.send(socket, response) do
      {:ok, request_bytes}
    end
  after
    :ssl.close(socket)
  end

  defp receive_headers(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      {:ok, bytes}
    else
      with {:ok, more} <- :ssl.recv(socket, 0, 5_000),
           do: receive_headers(socket, bytes <> more)
    end
  end

  defp receive_request(socket, bytes) do
    case :binary.match(bytes, "\r\n\r\n") do
      {header_end, 4} ->
        body_start = header_end + 4
        expected = content_length(binary_part(bytes, 0, header_end))
        receive_request_body(socket, bytes, body_start, expected)

      :nomatch ->
        with {:ok, more} <- :ssl.recv(socket, 0, 5_000),
             do: receive_request(socket, bytes <> more)
    end
  end

  defp receive_request_body(_, bytes, body_start, expected)
       when byte_size(bytes) - body_start >= expected,
       do: {:ok, binary_part(bytes, 0, body_start + expected)}

  defp receive_request_body(socket, bytes, body_start, expected) do
    with {:ok, more} <- :ssl.recv(socket, 0, 5_000),
         do: receive_request_body(socket, bytes <> more, body_start, expected)
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, &parse_content_length/1)
  end

  defp parse_content_length(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        if String.downcase(name) == "content-length",
          do: value |> String.trim() |> String.to_integer()

      _ ->
        nil
    end
  end

  defp json_http_response(status, document, extra_headers \\ []) do
    body = RFC8785.encode!(document)
    reason = if status == 200, do: "OK", else: "Accepted"

    headers =
      [
        {"Content-Type", "application/json"},
        {"Content-Length", Integer.to_string(byte_size(body))}
      ] ++
        extra_headers

    encoded_headers = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)
    "HTTP/1.1 #{status} #{reason}\r\n#{encoded_headers}\r\n#{body}"
  end

  defp frame_state(revision, display_state, desired, current, pending_request_id) do
    %{
      "stateRevision" => revision,
      "displayState" => display_state,
      "desiredAsset" => desired,
      "currentAsset" => current,
      "previousKnownGood" => nil,
      "pendingRequestId" => pending_request_id,
      "lastError" => nil
    }
  end
end
