defmodule Frameshift.Outbox.EndpointTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Outbox.Endpoint
  alias Frameshift.Outbox.HTTP1
  alias Frameshift.Outbox.TLSServer
  alias Frameshift.Playlist.Plan
  alias Frameshift.Protocol.JSON
  alias Frameshift.Transport.SPKIPin

  @frame_id "sim-photo-00000001"
  @profile_id "urn:frameshift:profile:sim-rgb24-v1"
  @bytes <<1, 2, 3, 4, 5, 6>>
  @next_bytes <<6, 5, 4, 3, 2, 1>>
  @thing_fixture Path.expand(
                   "../../../../../protocol/fixtures/valid/thing-description.json",
                   __DIR__
                 )

  setup_all do
    key = {:rsa, 2048, 65_537}

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: key], intermediates: [], peer: [key: key]},
        client_chain: %{root: [key: key], intermediates: [], peer: [key: key]}
      })

    certificate = Keyword.fetch!(certificates.server_config, :cert)
    unknown_certificate = Keyword.fetch!(certificates.client_config, :cert)
    assert {:ok, pin} = SPKIPin.fingerprint_der(certificate)
    assert {:ok, other_pin} = SPKIPin.fingerprint_der(unknown_certificate)
    refute pin == other_pin

    %{certificate: certificate, unknown_certificate: unknown_certificate, pin: pin}
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "frameshift-outbox-endpoint-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, library} = Library.start_link(data_dir: Path.join(root, "library"), name: nil)

    on_exit(fn -> Frameshift.TestSupport.stop_if_running(library) end)

    assert {:ok, _} =
             Library.register_paired_frame(
               library,
               File.read!(@thing_fixture),
               "keychain:outbox-endpoint-frame",
               context.pin
             )

    %{library: library, library_dir: Path.join(root, "library")}
  end

  test "serves only the authenticated frame's current manifest and exact bytes", context do
    assert {:ok, %{status: 204, body: <<>>}} = request(context, "GET", manifest_path())

    digest = register_artifact!(context.library, @bytes)
    assert {:ok, manifest} = Library.queue_outbox(context.library, @frame_id, digest, @profile_id)

    assert {:ok, %{status: 200, body: manifest_body, headers: manifest_headers}} =
             request(context, "GET", manifest_path())

    assert manifest_headers["content-length"] == Integer.to_string(byte_size(manifest_body))
    assert {:ok, ^manifest} = JSON.decode_control(manifest_body, "outbox-manifest")

    path = "/v0/outbox/assets/sha256/" <> Digest.hex!(digest)

    assert {:ok, %{status: 200, body: @bytes, headers: headers}} =
             request(context, "GET", path)

    assert headers["content-length"] == "6"
    assert headers["content-type"] == "application/vnd.frameshift.rgb24"

    assert headers["content-digest"] ==
             "sha-256=:#{Base.encode64(:crypto.hash(:sha256, @bytes))}:"

    next_digest = register_artifact!(context.library, @next_bytes)

    assert {:ok, _} =
             Library.queue_outbox(context.library, @frame_id, next_digest, @profile_id)

    assert {:error, :not_found} = request(context, "GET", path)

    assert {:ok, %{body: @next_bytes}} =
             request(context, "GET", "/v0/outbox/assets/sha256/" <> Digest.hex!(next_digest))

    assert {:error, :frame_not_paired} =
             Endpoint.handle(context.library, context.unknown_certificate, "GET", path, nil, <<>>)

    assert {:error, :invalid_peer_certificate} =
             Endpoint.handle(context.library, "another-frame", "GET", path, nil, <<>>)

    assert {:error, :not_found} =
             request(
               context,
               "GET",
               "/v0/outbox/assets/sha256/" <> String.duplicate("f", 64)
             )

    assert {:error, :invalid_request} =
             request(
               context,
               "GET",
               "/v0/outbox/assets/sha256/../" <> Digest.hex!(digest)
             )
  end

  test "only a schema-valid acknowledgement of the current revision can clear the outbox",
       context do
    digest = register_artifact!(context.library, @bytes)
    assert {:ok, manifest} = Library.queue_outbox(context.library, @frame_id, digest, @profile_id)

    acknowledgement = %{
      "manifestRevision" => manifest["revision"],
      "storage" => "verified",
      "refresh" => "displayed",
      "currentAsset" => digest,
      "lastError" => nil
    }

    assert {:error, :invalid_acknowledgement} =
             Endpoint.handle(
               context.library,
               context.certificate,
               "POST",
               "/v0/outbox/ack",
               "application/json",
               ~s({"manifestRevision":1,"storage":"verified","storage":"failed"})
             )

    assert {:error, :acknowledgement_conflict} =
             post_ack(context, %{acknowledgement | "manifestRevision" => 2})

    assert {:ok, ^manifest} = Library.outbox_manifest(context.library, @frame_id)

    assert {:ok, %{status: 200, body: ~s({"status":"confirmed"})}} =
             post_ack(context, acknowledgement)

    assert :empty = Library.outbox_manifest(context.library, @frame_id)

    assert {:error, :not_found} =
             request(
               context,
               "GET",
               "/v0/outbox/assets/sha256/" <> Digest.hex!(digest)
             )

    assert {:error, :acknowledgement_conflict} = post_ack(context, acknowledgement)

    assert {:ok, next_manifest} =
             Library.queue_outbox(context.library, @frame_id, digest, @profile_id)

    assert next_manifest["revision"] > manifest["revision"]
    assert {:error, :acknowledgement_conflict} = post_ack(context, acknowledgement)
    assert {:ok, ^next_manifest} = Library.outbox_manifest(context.library, @frame_id)

    assert {:ok, %{body: @bytes}} =
             request(
               context,
               "GET",
               "/v0/outbox/assets/sha256/" <> Digest.hex!(digest)
             )
  end

  test "a paired receiver fetches only its pending complete playlist and referenced assets",
       context do
    first = register_playlist_entry!(context.library, @bytes)
    second = register_playlist_entry!(context.library, @next_bytes)
    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)

    assert {:ok, plan} =
             Plan.build(
               frame["capabilities"],
               [first["artifactDigest"], second["artifactDigest"]],
               1_000
             )

    assert {:ok, manifest} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               plan.playlist,
               [first, second],
               "playlist-test"
             )

    revision = plan.playlist["revision"]
    assert manifest["playlistRevision"] == revision
    assert manifest["desiredAsset"] == first["artifactDigest"]
    path = "/v0/outbox/playlists/sha256/" <> Digest.hex!(revision)

    assert {:ok, %{status: 200, body: body, headers: headers}} = request(context, "GET", path)
    assert body == RFC8785.encode!(plan.playlist)
    assert headers["content-digest"] == "sha-256=:#{Base.encode64(:crypto.hash(:sha256, body))}:"

    second_path = "/v0/outbox/assets/sha256/" <> Digest.hex!(second["artifactDigest"])
    assert {:ok, %{status: 200, body: @next_bytes}} = request(context, "GET", second_path)

    assert {:error, :not_found} =
             request(context, "GET", "/v0/outbox/playlists/sha256/" <> String.duplicate("f", 64))

    assert {:ok, %{status: 200}} =
             post_ack(context, %{
               "manifestRevision" => manifest["revision"],
               "storage" => "verified",
               "refresh" => "displayed",
               "currentAsset" => first["artifactDigest"],
               "lastError" => nil
             })

    assert :empty = Library.outbox_manifest(context.library, @frame_id)
    assert {:error, :not_found} = request(context, "GET", path)
    assert {:error, :not_found} = request(context, "GET", second_path)

    assert {:error, :already_active} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               plan.playlist,
               [first, second]
             )

    assert :ok = Library.remove_master(context.library, second["masterDigest"])
    assert {:ok, []} = Library.collect_removed(context.library)
  end

  test "invalid and superseded playlist intents never expose stale assets", context do
    first = register_playlist_entry!(context.library, @bytes)
    second = register_playlist_entry!(context.library, @next_bytes)
    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)

    assert {:ok, plan} =
             Plan.build(
               frame["capabilities"],
               [first["artifactDigest"], second["artifactDigest"]],
               1_000
             )

    wrong =
      Map.put(plan.playlist, "entries", [
        %{"assetDigest" => second["artifactDigest"], "dwellMs" => 1_000}
      ])

    assert {:error, _} =
             Library.queue_playlist(context.library, @frame_id, @profile_id, wrong, [first])

    assert :empty = Library.outbox_manifest(context.library, @frame_id)

    assert {:ok, manifest} =
             Library.queue_playlist(context.library, @frame_id, @profile_id, plan.playlist, [
               first,
               second
             ])

    path = "/v0/outbox/playlists/sha256/" <> Digest.hex!(plan.playlist["revision"])
    assert {:ok, %{status: 200}} = request(context, "GET", path)

    assert {:error, :playlist_pending} =
             Library.queue_playlist(context.library, @frame_id, @profile_id, plan.playlist, [
               first,
               second
             ])

    assert {:ok, newer} =
             Library.queue_outbox(
               context.library,
               @frame_id,
               first["artifactDigest"],
               @profile_id
             )

    assert newer["revision"] > manifest["revision"]
    assert newer["playlistRevision"] == nil
    assert {:error, :not_found} = request(context, "GET", path)

    assert {:error, :not_found} =
             request(
               context,
               "GET",
               "/v0/outbox/assets/sha256/" <> Digest.hex!(second["artifactDigest"])
             )
  end

  test "a suspended loop can be requeued with the same revision after a single still", context do
    first = register_playlist_entry!(context.library, @bytes)
    second = register_playlist_entry!(context.library, @next_bytes)
    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)

    {:ok, plan} =
      Plan.build(
        frame["capabilities"],
        [first["artifactDigest"], second["artifactDigest"]],
        1_000
      )

    entries = [first, second]

    assert {:ok, initial} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               plan.playlist,
               entries
             )

    assert {:ok, %{status: 200}} =
             post_ack(context, displayed_ack(initial, first["artifactDigest"]))

    assert %{"status" => "active"} = Library.frame_playlist_status(context.library, @frame_id)

    {:ok, replacement} =
      Plan.build(
        frame["capabilities"],
        [first["artifactDigest"], second["artifactDigest"]],
        2_000
      )

    assert {:ok, _} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               replacement.playlist,
               entries
             )

    assert %{"status" => "pending", "replacingActive" => true} =
             Library.frame_playlist_status(context.library, @frame_id)

    assert {:ok, single} =
             Library.queue_outbox(
               context.library,
               @frame_id,
               first["artifactDigest"],
               @profile_id
             )

    assert {:ok, %{status: 200}} =
             post_ack(context, displayed_ack(single, first["artifactDigest"]))

    assert %{"status" => "suspended"} =
             Library.frame_playlist_status(context.library, @frame_id)

    assert {:ok, another_single} =
             Library.queue_outbox(
               context.library,
               @frame_id,
               first["artifactDigest"],
               @profile_id
             )

    assert {:ok, %{status: 200}} =
             post_ack(context, displayed_ack(another_single, first["artifactDigest"]))

    assert %{"status" => "suspended"} =
             Library.frame_playlist_status(context.library, @frame_id)

    assert {:ok, resumed} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               plan.playlist,
               entries
             )

    assert resumed["playlistRevision"] == plan.playlist["revision"]
    assert %{"status" => "pending"} = Library.frame_playlist_status(context.library, @frame_id)
  end

  test "a duplicate paired SPKI is rejected before it can affect frame resolution", context do
    another_td =
      @thing_fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("id", "urn:frameshift:device:another-frame-0001")
      |> Map.put("title", "Another frame")
      |> put_in(["frameshift:capabilities", "deviceId"], "another-frame-0001")
      |> Jason.encode!()

    assert {:error, :server_fingerprint_in_use} =
             Library.register_paired_frame(
               context.library,
               another_td,
               "keychain:another-frame",
               context.pin
             )

    assert {:ok, %{status: 204}} = request(context, "GET", manifest_path())
  end

  test "resume refuses stale revision, newer delivery and changed capabilities", context do
    {plan, first, second} = suspended_playlist(context)
    revision = plan.playlist["revision"]

    assert {:error, :playlist_revision_conflict} =
             Library.resume_playlist(context.library, @frame_id, Digest.sha256("stale"))

    {:ok, single} =
      Library.queue_outbox(context.library, @frame_id, first["artifactDigest"], @profile_id)

    assert {:error, :playlist_pending} =
             Library.resume_playlist(context.library, @frame_id, revision)

    assert {:ok, ^single} = Library.outbox_manifest(context.library, @frame_id)

    assert {:ok, %{status: 200}} =
             post_ack(context, displayed_ack(single, first["artifactDigest"]))

    {:ok, injector} =
      Exqlite.start_link(database: Path.join(context.library_dir, "metadata.sqlite"))

    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)
    changed = put_in(frame["capabilities"], ["refresh", "minimumDwellMs"], 2_000)

    Exqlite.query!(
      injector,
      "UPDATE paired_frames SET capabilities_json = ? WHERE frame_id = ?",
      [Jason.encode!(changed), @frame_id]
    )

    GenServer.stop(injector)

    assert {:error, :playlist_profile_changed} =
             Library.resume_playlist(context.library, @frame_id, revision)

    assert %{"status" => "suspended", "requiresRevalidation" => true} =
             Library.frame_playlist_status(context.library, @frame_id)

    assert %{"requiresReview" => true} =
             Library.frame_playlist_interval(context.library, @frame_id)

    assert :empty = Library.outbox_manifest(context.library, @frame_id)
    assert :ok = Library.remove_master(context.library, second["masterDigest"])
    assert {:ok, []} = Library.collect_removed(context.library)
  end

  test "failed resume or replacement rolls back body, preferences, outbox revision and references",
       context do
    {plan, first, second} = suspended_playlist(context)
    revision = plan.playlist["revision"]
    preference = Library.frame_playlist_interval(context.library, @frame_id)

    {:ok, injector} =
      Exqlite.start_link(database: Path.join(context.library_dir, "metadata.sqlite"))

    Exqlite.query!(
      injector,
      "CREATE TRIGGER fail_playlist_outbox BEFORE INSERT ON frame_outboxes BEGIN SELECT RAISE(ABORT, 'injected playlist failure'); END"
    )

    assert {:error, {:database, "injected playlist failure"}} =
             Library.resume_playlist(context.library, @frame_id, revision)

    assert %{"status" => "suspended", "revision" => ^revision} =
             Library.frame_playlist_status(context.library, @frame_id)

    assert :empty = Library.outbox_manifest(context.library, @frame_id)
    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)

    {:ok, replacement} =
      Plan.build(
        frame["capabilities"],
        [second["artifactDigest"], first["artifactDigest"]],
        2_000
      )

    assert {:error, {:database, "injected playlist failure"}} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               replacement.playlist,
               [second, first],
               "replacement-failed",
               {:override, 2_000}
             )

    assert Library.frame_playlist_interval(context.library, @frame_id) == preference

    assert %{"status" => "suspended", "revision" => ^revision} =
             Library.frame_playlist_status(context.library, @frame_id)

    assert :empty = Library.outbox_manifest(context.library, @frame_id)
    Exqlite.query!(injector, "DROP TRIGGER fail_playlist_outbox")
    GenServer.stop(injector)

    assert {:ok, resumed} =
             Library.resume_playlist(context.library, @frame_id, revision, "resume-after-failure")

    assert resumed["revision"] == 3
    assert {:ok, body} = Library.outbox_playlist(context.library, @frame_id, revision)
    assert body == RFC8785.encode!(plan.playlist)

    assert {:error, :playlist_revision_conflict} =
             Library.resume_playlist(context.library, @frame_id, revision)

    assert Process.alive?(context.library)
  end

  test "an unresolved push on a dual-mode frame refuses both playlist writers", context do
    {plan, first, second} = suspended_playlist(context)

    assert {:ok, _} =
             Library.begin_direct_delivery(
               context.library,
               @frame_id,
               first["artifactDigest"],
               @profile_id,
               "unresolved-push"
             )

    assert {:error, :direct_delivery_pending} =
             Library.resume_playlist(context.library, @frame_id, plan.playlist["revision"])

    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)

    {:ok, replacement} =
      Plan.build(
        frame["capabilities"],
        [first["artifactDigest"], second["artifactDigest"]],
        2_000
      )

    assert {:error, :direct_delivery_pending} =
             Library.queue_playlist(
               context.library,
               @frame_id,
               @profile_id,
               replacement.playlist,
               [first, second]
             )

    assert %{"status" => "suspended"} = Library.frame_playlist_status(context.library, @frame_id)
    assert :empty = Library.outbox_manifest(context.library, @frame_id)
  end

  defp suspended_playlist(context) do
    first = register_playlist_entry!(context.library, @bytes)
    second = register_playlist_entry!(context.library, @next_bytes)
    {:ok, frame} = Library.get_paired_frame(context.library, @frame_id)

    {:ok, plan} =
      Plan.build(
        frame["capabilities"],
        [second["artifactDigest"], first["artifactDigest"]],
        1_501
      )

    {:ok, initial} =
      Library.queue_playlist(
        context.library,
        @frame_id,
        @profile_id,
        plan.playlist,
        [second, first],
        "ordered-fixture",
        {:override, 1_501}
      )

    {:ok, %{status: 200}} = post_ack(context, displayed_ack(initial, second["artifactDigest"]))

    {:ok, single} =
      Library.queue_outbox(context.library, @frame_id, first["artifactDigest"], @profile_id)

    {:ok, %{status: 200}} = post_ack(context, displayed_ack(single, first["artifactDigest"]))
    {plan, first, second}
  end

  test "the bounded HTTP exchange frames authenticated content and safe problems", context do
    digest = register_artifact!(context.library, @bytes)

    assert {:ok, _} =
             Library.queue_outbox(context.library, @frame_id, digest, @profile_id)

    request = "GET /v0/outbox/manifest HTTP/1.1\r\nHost: host.local\r\n\r\n"

    assert {:ok, response} = HTTP1.exchange(context.library, context.certificate, request)
    assert response =~ "HTTP/1.1 200 OK\r\n"
    assert response =~ "content-type: application/json\r\n"
    assert response =~ "connection: close\r\n"

    [head, body] = :binary.split(response, "\r\n\r\n")
    assert head =~ "content-length: #{byte_size(body)}\r\n"
    assert {:ok, %{"desiredAsset" => ^digest}} = JSON.decode_control(body, "outbox-manifest")

    assert {:ok, forbidden} =
             HTTP1.exchange(context.library, context.unknown_certificate, request)

    assert forbidden =~ "HTTP/1.1 403 Forbidden\r\n"
    assert forbidden =~ "content-type: application/problem+json\r\n"
    refute forbidden =~ @frame_id
    refute forbidden =~ digest

    assert {:ok, malformed} =
             HTTP1.exchange(
               context.library,
               context.certificate,
               request <> "GET /v0/outbox/manifest HTTP/1.1\r\n\r\n"
             )

    assert malformed =~ "HTTP/1.1 400 Bad Request\r\n"
  end

  test "the TLS verification callback pins only one paired pull-capable frame", context do
    certificate = :public_key.pkix_decode_cert(context.certificate, :otp)
    unknown_certificate = :public_key.pkix_decode_cert(context.unknown_certificate, :otp)
    state = %{library: context.library}

    assert {:valid, ^state} =
             TLSServer.verify_client(certificate, {:bad_cert, :unknown_ca}, state)

    assert {:fail, {:bad_cert, :cert_expired}} =
             TLSServer.verify_client(certificate, {:bad_cert, :cert_expired}, state)

    assert {:valid, %{matched: true}} = TLSServer.verify_client(certificate, :valid_peer, state)

    assert {:fail, :unpaired_frame} =
             TLSServer.verify_client(unknown_certificate, :valid_peer, state)
  end

  defp request(context, method, path) do
    Endpoint.handle(context.library, context.certificate, method, path, nil, <<>>)
  end

  defp post_ack(context, acknowledgement) do
    {:ok, body} = JSON.encode(acknowledgement)

    Endpoint.handle(
      context.library,
      context.certificate,
      "POST",
      "/v0/outbox/ack",
      "application/json",
      body
    )
  end

  defp displayed_ack(manifest, digest) do
    %{
      "manifestRevision" => manifest["revision"],
      "storage" => "verified",
      "refresh" => "displayed",
      "currentAsset" => digest,
      "lastError" => nil
    }
  end

  defp manifest_path, do: "/v0/outbox/manifest"

  defp register_artifact!(library, bytes) do
    {:ok, master} =
      Library.import_master(library, "master-#{Digest.sha256(bytes)}", %{
        title: "Endpoint fixture",
        source_kind: :import,
        width: 2,
        height: 1,
        media_type: "image/png",
        provenance: %{"kind" => "test-fixture"}
      })

    {:ok, recipe_hash} =
      Library.register_recipe(library, :composition, %{"width" => 2, "height" => 1}, [
        master["digest"]
      ])

    {:ok, artifact} =
      Library.register_artifact(library, bytes, %{
        master_digest: master["digest"],
        recipe_hash: recipe_hash,
        profile_id: @profile_id,
        renderer_revision: "outbox-endpoint-test-v1",
        media_type: "application/vnd.frameshift.rgb24"
      })

    artifact["digest"]
  end

  defp register_playlist_entry!(library, bytes) do
    digest = register_artifact!(library, bytes)

    %{
      "masterDigest" => Digest.sha256("master-#{Digest.sha256(bytes)}"),
      "artifactDigest" => digest
    }
  end
end
