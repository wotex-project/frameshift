defmodule Frameshift.SimulatorProfileCustodyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Qualification.Profile
  alias Frameshift.Simulator
  alias Frameshift.Simulator.Persistence
  alias Frameshift.Simulator.State

  @profile_id "urn:frameshift:test:indexed4-msb-v1"

  setup do
    root = Path.join(System.tmp_dir!(), "frame-profile-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, capabilities: capabilities()}
  end

  test "unchanged profile survives restart and cached outbox replay without rewriting assets",
       ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    digest = upload(frame, <<0x56>>)
    path = ContentStore.object_path(ctx.root, digest)
    inode = File.stat!(path).inode
    {:ok, profile_digest} = Profile.digest(ctx.capabilities, @profile_id)
    {:ok, payload} = Persistence.load(ctx.root)
    assert payload["assets"][digest]["profileDigest"] == profile_digest
    assert {:ok, :existing} = Simulator.put_asset(frame, digest, @profile_id, <<0x56>>)
    assert {:ok, first} = Simulator.pull_outbox(frame, manifest(digest), nil)
    assert first["refresh"] == "displayed"

    restarted = restart_frame(ctx.root, ctx.capabilities)
    assert Simulator.has_compatible_asset?(restarted, digest, @profile_id)
    assert {:ok, ^first} = Simulator.pull_outbox(restarted, manifest(digest), nil)
    assert File.stat!(path).inode == inode
    assert File.read!(path) == <<0x56>>
    assert Simulator.state(restarted).state["storage"]["health"] == "ok"
  end

  test "profile changes refuse every activation path while retaining last-valid artwork", ctx do
    variants = [
      put_in(
        ctx.capabilities,
        ["storage", "artifactProfiles", Access.at(0), "paletteRevision"],
        "v2"
      ),
      put_in(ctx.capabilities, ["color", "palette", Access.at(4), "previewSrgb"], [1, 2, 255]),
      put_in(ctx.capabilities, ["color", "palette", Access.at(5), "wireCode"], 7),
      put_in(
        ctx.capabilities,
        ["storage", "artifactProfiles", Access.at(0), "packing"],
        "unknown-v2"
      ),
      put_in(ctx.capabilities, ["geometry", "orientation"], "rotate-180")
    ]

    for {changed, index} <- Enum.with_index(variants) do
      root = Path.join(ctx.root, Integer.to_string(index))
      frame = start_frame(root, ctx.capabilities)
      first = upload(frame, <<0x56>>)
      second = upload(frame, <<0x65>>)
      assert {:ok, _} = Simulator.set_desired(frame, desired(first, "first"), "*")
      assert {:ok, _} = Simulator.set_desired(frame, desired(second, "second"), etag(frame))
      playlist = playlist([first, second])
      assert {:ok, _} = Simulator.set_playlist(frame, playlist, etag(frame))
      {:ok, before} = Persistence.load(root)
      restarted = restart_frame(root, changed)
      snapshot = Simulator.state(restarted)

      assert snapshot.state["displayState"] == "recovering"
      assert snapshot.state["storage"]["health"] == "degraded"
      assert snapshot.state["currentAsset"] == second
      assert snapshot.state["previousKnownGood"] == first
      assert snapshot.state["desiredAsset"] == second
      assert Simulator.has_asset?(restarted, second)
      refute Simulator.has_compatible_asset?(restarted, second, @profile_id)
      assert {:error, :asset_missing} = Simulator.pull_outbox(restarted, manifest(second), nil)
      assert {:error, :unsupported_profile} = Simulator.retry_display(restarted)

      assert {:error, :unsupported_profile} =
               Simulator.set_desired(restarted, desired(second, "second"), "stale")

      assert {:error, :unsupported_profile} =
               Simulator.set_desired(restarted, desired(second, "new"), snapshot.etag)

      assert {:error, :unsupported_profile} = Simulator.set_playlist(restarted, playlist, "stale")
      assert {:error, :unsupported_profile} = Simulator.advance_playlist(restarted, 1_000)
      assert {:error, :asset_referenced} = Simulator.delete_asset(restarted, first)
      assert {:error, :asset_referenced} = Simulator.delete_asset(restarted, second)
      assert Simulator.state(restarted) == snapshot
      {:ok, after_restart} = Persistence.load(root)
      assert after_restart["assets"] == before["assets"]
      assert File.read!(ContentStore.object_path(root, first)) == <<0x56>>
      assert File.read!(ContentStore.object_path(root, second)) == <<0x65>>
    end
  end

  test "metadata conflict never relabels bytes and degradation persists across recovery", ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    digest = upload(frame, <<0x56>>)
    assert {:ok, _} = Simulator.pull_outbox(frame, manifest(digest), nil)
    {:ok, before} = Persistence.load(ctx.root)
    path = ContentStore.object_path(ctx.root, digest)
    inode = File.stat!(path).inode

    changed =
      put_in(ctx.capabilities, ["color", "palette", Access.at(4), "previewSrgb"], [1, 2, 255])

    restarted = restart_frame(ctx.root, changed)

    assert {:error, :asset_metadata_conflict} =
             Simulator.pull_outbox(restarted, manifest(digest), <<0x56>>)

    {:ok, conflicted} = Persistence.load(ctx.root)
    assert conflicted["assets"] == before["assets"]
    assert conflicted["currentAsset"] == before["currentAsset"]
    assert conflicted["storageDegraded"]
    assert conflicted["lastError"]["type"] == "urn:frameshift:problem:asset-metadata-conflict"
    assert File.stat!(path).inode == inode

    restored = restart_frame(ctx.root, ctx.capabilities)
    assert Simulator.has_compatible_asset?(restored, digest, @profile_id)
    assert {:ok, _} = Simulator.retry_display(restored)
    assert Simulator.state(restored).state["storage"]["health"] == "degraded"

    assert restart_frame(ctx.root, ctx.capabilities)
           |> Simulator.state()
           |> get_in([:state, "storage", "health"]) == "degraded"
  end

  test "new compatible artwork can activate without repairing stale stored metadata", ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    first = upload(frame, <<0x56>>)
    assert {:ok, _} = Simulator.set_desired(frame, desired(first, "first"), "*")

    changed =
      put_in(
        ctx.capabilities,
        ["storage", "artifactProfiles", Access.at(0), "paletteRevision"],
        "v2"
      )

    restarted = restart_frame(ctx.root, changed)
    second = upload(restarted, <<0x65>>)

    assert {:ok, displayed} =
             Simulator.set_desired(restarted, desired(second, "second"), etag(restarted))

    assert displayed["currentAsset"] == second
    assert displayed["previousKnownGood"] == first
    assert displayed["storage"]["health"] == "degraded"
    assert {:error, :asset_referenced} = Simulator.delete_asset(restarted, first)
    refute Simulator.has_compatible_asset?(restarted, first, @profile_id)
    assert Simulator.has_compatible_asset?(restarted, second, @profile_id)
  end

  test "missing frozen identity refuses without upgrading a valid checksummed record", ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    digest = upload(frame, <<0x56>>)
    assert {:ok, _} = Simulator.set_desired(frame, desired(digest, "first"), "*")
    stop_supervised!(ctx.root)
    {:ok, payload} = Persistence.load(ctx.root)
    incomplete = update_in(payload, ["assets", digest], &Map.delete(&1, "profileDigest"))

    assert :ok =
             incomplete
             |> State.from_persisted(ctx.capabilities, ctx.root)
             |> State.bump()
             |> Persistence.save()

    restarted = start_frame(ctx.root, ctx.capabilities)

    assert Simulator.state(restarted).state["displayState"] == "recovering"
    assert {:error, :unsupported_profile} = Simulator.retry_display(restarted)

    assert {:error, :asset_metadata_conflict} =
             Simulator.put_asset(restarted, digest, @profile_id, <<0x56>>)

    {:ok, retained} = Persistence.load(ctx.root)
    refute Map.has_key?(retained["assets"][digest], "profileDigest")
    assert File.read!(ContentStore.object_path(ctx.root, digest)) == <<0x56>>
  end

  test "duplicate profile IDs refuse qualification and receiver cache selection", ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    digest = upload(frame, <<0x56>>)
    [profile] = ctx.capabilities["storage"]["artifactProfiles"]

    duplicate =
      put_in(ctx.capabilities, ["storage", "artifactProfiles"], [
        profile,
        Map.put(profile, "paletteRevision", "v2")
      ])

    assert {:error, :unsupported_profile} = Profile.digest(duplicate, @profile_id)
    restarted = restart_frame(ctx.root, duplicate)
    refute Simulator.has_compatible_asset?(restarted, digest, @profile_id)

    assert {:error, :unsupported_profile} =
             Simulator.put_asset(restarted, digest, @profile_id, <<0x56>>)

    assert {:error, :unsupported_profile} =
             Simulator.set_desired(restarted, desired(digest, "first"), "*")
  end

  test "mutable capacity and firmware observations do not invalidate unchanged artifact bytes",
       ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    digest = upload(frame, <<0x56>>)

    changed =
      ctx.capabilities
      |> put_in(["storage", "availableBytes"], 1)
      |> Map.put("firmwareVersion", "simulator-0.2")

    restarted = restart_frame(ctx.root, changed)
    assert Simulator.has_compatible_asset?(restarted, digest, @profile_id)
    assert {:ok, ack} = Simulator.pull_outbox(restarted, manifest(digest), nil)
    assert ack["refresh"] == "displayed"
    assert Simulator.state(restarted).state["storage"]["health"] == "ok"
  end

  defp start_frame(root, capabilities) do
    start_supervised!(
      Supervisor.child_spec({Simulator, data_dir: root, capabilities: capabilities, name: nil},
        id: root
      )
    )
  end

  defp restart_frame(root, capabilities) do
    stop_supervised!(root)
    start_frame(root, capabilities)
  end

  defp upload(frame, bytes) do
    digest = Digest.sha256(bytes)
    assert {:ok, :created} = Simulator.put_asset(frame, digest, @profile_id, bytes)
    digest
  end

  defp etag(frame), do: Simulator.state(frame).etag

  defp desired(digest, request_id),
    do: %{"assetDigest" => digest, "artifactProfile" => @profile_id, "requestId" => request_id}

  defp manifest(digest),
    do: %{
      "revision" => 1,
      "desiredAsset" => digest,
      "artifactProfile" => @profile_id,
      "playlistRevision" => nil
    }

  defp playlist(digests) do
    payload = %{
      "mode" => "cycle",
      "entries" => Enum.map(digests, &%{"assetDigest" => &1, "dwellMs" => 1_000})
    }

    Map.put(payload, "revision", Digest.sha256(RFC8785.encode!(payload)))
  end

  defp capabilities do
    Path.expand("../../../../protocol/fixtures/valid/capabilities-paper-indexed4.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> put_in(["geometry", "width"], 2)
    |> put_in(["geometry", "height"], 1)
    |> put_in(["storage", "maximumAssetBytes"], 1)
    |> put_in(["storage", "totalBytes"], 2)
    |> put_in(["storage", "availableBytes"], 2)
    |> put_in(["storage", "artifactProfiles", Access.at(0), "width"], 2)
    |> put_in(["storage", "artifactProfiles", Access.at(0), "height"], 1)
    |> put_in(["storage", "artifactProfiles", Access.at(0), "maximumAssetBytes"], 1)
  end
end
