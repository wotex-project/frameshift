defmodule Frameshift.SimulatorIntegrityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Simulator
  alias Frameshift.Simulator.Persistence
  alias Frameshift.Simulator.State

  @profile_id "urn:frameshift:test:indexed4-msb-v1"

  setup do
    root = Path.join(System.tmp_dir!(), "frame-integrity-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, capabilities: capabilities()}
  end

  test "boot retains recovery state for changed, truncated, grown and missing objects", ctx do
    variants = [
      {"changed", fn path -> File.write!(path, <<0x65>>) end},
      {"truncated", fn path -> File.write!(path, <<>>) end},
      {"grown", fn path -> File.write!(path, <<0x56, 0x65>>) end},
      {"missing", fn path -> File.rm!(path) end}
    ]

    for {label, mutate} <- variants do
      root = Path.join(ctx.root, label)
      frame = start_frame(root, ctx.capabilities)
      {current, previous} = display_pair(frame)
      stop_supervised!(root)
      {:ok, before} = Persistence.load(root)
      mutate.(ContentStore.object_path(root, current))
      restarted = start_frame(root, ctx.capabilities)
      assert_recovery(restarted, root, before, current, previous)
      assert Simulator.has_compatible_asset?(restarted, previous, @profile_id)

      assert {:ok, repaired_display} =
               Simulator.set_desired(
                 restarted,
                 desired(previous, "recover-valid"),
                 etag(restarted)
               )

      assert repaired_display["currentAsset"] == previous
      assert repaired_display["previousKnownGood"] == current
      assert repaired_display["storage"]["health"] == "degraded"
    end
  end

  test "boot refuses symlink, directory and FIFO objects without reading or repairing them",
       ctx do
    for kind <- [:symlink, :directory, :fifo] do
      root = Path.join(ctx.root, Atom.to_string(kind))
      frame = start_frame(root, ctx.capabilities)
      {current, previous} = display_pair(frame)
      stop_supervised!(root)
      {:ok, before} = Persistence.load(root)
      path = ContentStore.object_path(root, current)
      File.rm!(path)
      sentinel = Path.join(root, "sentinel")
      File.write!(sentinel, <<0x56>>)
      sentinel_inode = File.stat!(sentinel).inode
      create_nonregular(kind, path, sentinel)
      started = System.monotonic_time(:millisecond)
      restarted = start_frame(root, ctx.capabilities)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert_recovery(restarted, root, before, current, previous)
      assert File.lstat!(path).type == kind_type(kind)
      assert File.read!(sentinel) == <<0x56>>
      assert File.stat!(sentinel).inode == sentinel_inode
    end
  end

  test "live cache corruption cannot borrow displayed, desired, retry or playlist completion",
       ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    {current, previous} = display_pair(frame)
    playlist = playlist([current, previous])
    assert {:ok, _} = Simulator.set_playlist(frame, playlist, etag(frame))
    before = Simulator.state(frame)
    {:ok, before_payload} = Persistence.load(ctx.root)
    path = ContentStore.object_path(ctx.root, current)
    File.write!(path, <<0x65>>)
    inode = File.stat!(path).inode

    refute Simulator.has_compatible_asset?(frame, current, @profile_id)
    assert {:error, :unsupported_profile} = Simulator.pull_outbox(frame, manifest(current), nil)
    assert {:error, :unsupported_profile} = Simulator.retry_display(frame)

    assert {:error, :unsupported_profile} =
             Simulator.set_desired(frame, desired(current, "current"), "stale")

    assert {:error, :unsupported_profile} = Simulator.set_playlist(frame, playlist, "stale")
    assert {:error, :unsupported_profile} = Simulator.advance_playlist(frame, 1_000)

    assert {:error, :content_address_collision} =
             Simulator.put_asset(frame, current, @profile_id, <<0x56>>)

    assert Simulator.state(frame) == before
    assert File.read!(path) == <<0x65>>
    assert File.stat!(path).inode == inode
    stop_supervised!(ctx.root)
    restarted = start_frame(ctx.root, ctx.capabilities)
    assert_recovery(restarted, ctx.root, before_payload, current, previous)
  end

  test "valid hash does not excuse wrong recorded length or repeated recovery writes", ctx do
    frame = start_frame(ctx.root, ctx.capabilities)
    {current, previous} = display_pair(frame)
    stop_supervised!(ctx.root)
    {:ok, payload} = Persistence.load(ctx.root)
    changed = put_in(payload, ["assets", current, "byteCount"], 2)

    assert :ok =
             changed
             |> State.from_persisted(ctx.capabilities, ctx.root)
             |> State.bump()
             |> Persistence.save()

    restarted = start_frame(ctx.root, ctx.capabilities)
    assert_recovery(restarted, ctx.root, changed, current, previous)
    snapshot = Simulator.state(restarted)
    stop_supervised!(ctx.root)
    assert Simulator.state(start_frame(ctx.root, ctx.capabilities)) == snapshot
    assert File.read!(ContentStore.object_path(ctx.root, current)) == <<0x56>>
  end

  defp assert_recovery(frame, root, before, current, previous) do
    snapshot = Simulator.state(frame)
    assert snapshot.state["displayState"] == "recovering"
    assert snapshot.state["storage"]["health"] == "degraded"
    assert snapshot.state["lastError"]["type"] == "urn:frameshift:problem:asset-corrupt"
    assert snapshot.state["currentAsset"] == current
    assert snapshot.state["desiredAsset"] == current
    assert snapshot.state["previousKnownGood"] == previous
    assert {:error, :asset_referenced} = Simulator.delete_asset(frame, current)
    assert {:error, :asset_referenced} = Simulator.delete_asset(frame, previous)
    refute Simulator.has_compatible_asset?(frame, current, @profile_id)
    assert {:error, :asset_missing} = Simulator.pull_outbox(frame, manifest(current), nil)
    assert {:error, :unsupported_profile} = Simulator.retry_display(frame)
    assert Simulator.state(frame) == snapshot
    {:ok, retained} = Persistence.load(root)
    assert retained["assets"] == before["assets"]
  end

  defp display_pair(frame) do
    previous = upload(frame, <<0x65>>)
    current = upload(frame, <<0x56>>)
    assert {:ok, _} = Simulator.set_desired(frame, desired(previous, "previous"), "*")
    assert {:ok, _} = Simulator.set_desired(frame, desired(current, "current"), etag(frame))
    {current, previous}
  end

  defp start_frame(root, capabilities) do
    start_supervised!(
      Supervisor.child_spec({Simulator, data_dir: root, capabilities: capabilities, name: nil},
        id: root
      )
    )
  end

  defp upload(frame, bytes) do
    digest = Digest.sha256(bytes)
    assert {:ok, :created} = Simulator.put_asset(frame, digest, @profile_id, bytes)
    digest
  end

  defp create_nonregular(:symlink, path, sentinel), do: File.ln_s!(sentinel, path)
  defp create_nonregular(:directory, path, _), do: File.mkdir!(path)

  defp create_nonregular(:fifo, path, _) do
    assert {"", 0} = System.cmd("mkfifo", [path])
  end

  defp kind_type(:fifo), do: :other
  defp kind_type(kind), do: kind
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
