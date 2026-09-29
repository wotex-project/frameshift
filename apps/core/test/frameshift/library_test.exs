defmodule Frameshift.LibraryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Library.Backup

  @frame_fixture Path.expand(
                   "../../../../protocol/fixtures/valid/thing-description.json",
                   __DIR__
                 )
  @frame_fingerprint "sha256:" <> String.duplicate("b", 64)

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "frameshift-library-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    {:ok, library} = Library.start_link(data_dir: data_dir, name: nil)
    %{library: library, data_dir: data_dir}
  end

  test "committed masters survive a clean core restart", %{library: library, data_dir: data_dir} do
    {:ok, imported} = Library.import_master(library, "master bytes", master_attributes())

    assert imported[:placement] == :created
    assert File.read!(ContentStore.object_path(data_dir, imported["digest"])) == "master bytes"

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, persisted} = Library.get_master(restarted, imported["digest"])
    assert persisted["title"] == "Morning Study"
    assert persisted["provenance_json"] == %{"kind" => "local-import"}

    assert {:ok, stored} = Library.read_object(restarted, imported["digest"])
    assert stored["bytes"] == "master bytes"
    assert stored["media_type"] == "image/png"

    GenServer.stop(restarted)
  end

  test "backup restores protected and trashed objects with the same metadata", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, protected} =
      Library.import_master(
        library,
        "protected backup bytes",
        master_attributes(%{title: "Protected"})
      )

    {:ok, removed} =
      Library.import_master(
        library,
        "removed backup bytes",
        master_attributes(%{title: "Removed"})
      )

    :ok = Library.protect_frame_asset(library, "frame-1", "current", protected["digest"])
    :ok = Library.remove_master(library, removed["digest"])
    assert {:ok, [removed_digest]} = Library.collect_removed(library)
    assert removed_digest == removed["digest"]

    backup_dir = data_dir <> "-backup"
    restored_dir = data_dir <> "-restored"

    on_exit(fn ->
      File.rm_rf!(backup_dir)
      File.rm_rf!(restored_dir)
    end)

    assert :ok = Library.create_backup(library, backup_dir)
    assert :ok = Backup.verify(backup_dir)
    assert {:error, :backup_destination_exists} = Library.create_backup(library, backup_dir)

    assert {:error, :backup_inside_library} =
             Library.create_backup(library, Path.join(data_dir, "unsafe-backup"))

    assert :ok = Backup.restore(backup_dir, restored_dir)
    assert {:ok, restored} = Library.start_link(data_dir: restored_dir, name: nil)
    assert [%{"digest" => digest}] = Library.search(restored, "protect")
    assert digest == protected["digest"]

    assert {:ok, %{"bytes" => "protected backup bytes"}} =
             Library.read_object(restored, protected["digest"])

    assert :ok = Library.restore_master(restored, removed_digest)

    assert {:ok, %{"bytes" => "removed backup bytes"}} =
             Library.read_object(restored, removed_digest)

    GenServer.stop(restored)
  end

  test "restore rejects corrupted backup bytes without publishing a destination", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, master} = Library.import_master(library, "untouched bytes", master_attributes())
    backup_dir = data_dir <> "-corrupt-backup"
    destination = data_dir <> "-rejected-restore"

    on_exit(fn ->
      File.rm_rf!(backup_dir)
      File.rm_rf!(destination)
    end)

    assert :ok = Library.create_backup(library, backup_dir)
    File.write!(ContentStore.object_path(backup_dir, master["digest"]), "tampered bytes")

    assert {:error, :invalid_backup_file} = Backup.restore(backup_dir, destination)
    refute File.exists?(destination)

    assert {:ok, %{"bytes" => "untouched bytes"}} =
             Library.read_object(library, master["digest"])
  end

  test "command receipts preserve terminal outcomes and pending crash windows across restart", %{
    library: library,
    data_dir: data_dir
  } do
    success_hash = Digest.sha256("successful command")
    failure_hash = Digest.sha256("failed command")
    pending_hash = Digest.sha256("pending command")

    assert {:ok, :execute} = Library.claim_command(library, "success-id", success_hash)
    assert {:ok, :pending} = Library.claim_command(library, "success-id", success_hash)
    assert :ok = Library.complete_command(library, "success-id", success_hash, :ok)
    assert :ok = Library.complete_command(library, "success-id", success_hash, :ok)
    assert {:ok, {:replay, :ok}} = Library.claim_command(library, "success-id", success_hash)

    assert {:ok, :execute} = Library.claim_command(library, "failure-id", failure_hash)

    assert :ok =
             Library.complete_command(library, "failure-id", failure_hash, {
               :error,
               :invalid_command
             })

    assert {:ok, {:replay, {:error, "invalid_command"}}} =
             Library.claim_command(library, "failure-id", failure_hash)

    assert {:ok, :execute} = Library.claim_command(library, "pending-id", pending_hash)
    assert {:ok, :pending} = Library.claim_command(library, "pending-id", pending_hash)

    assert {:error, :command_id_conflict} =
             Library.claim_command(library, "success-id", Digest.sha256("different command"))

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, {:replay, :ok}} =
             Library.claim_command(restarted, "success-id", success_hash)

    assert {:ok, {:replay, {:error, "invalid_command"}}} =
             Library.claim_command(restarted, "failure-id", failure_hash)

    assert {:ok, :pending} = Library.claim_command(restarted, "pending-id", pending_hash)

    GenServer.stop(restarted)
  end

  test "command receipt input is bounded and completion is identity checked", %{library: library} do
    hash = Digest.sha256("command")

    assert {:error, :invalid_command_receipt} = Library.claim_command(library, "", hash)

    assert {:error, :invalid_command_receipt} =
             Library.claim_command(library, String.duplicate("a", 65), hash)

    assert {:error, :invalid_command_hash} =
             Library.claim_command(library, "command-id", "not-a-digest")

    assert {:error, :command_receipt_missing} =
             Library.complete_command(library, "command-id", hash, :ok)

    assert {:ok, :execute} = Library.claim_command(library, "command-id", hash)

    assert {:error, :command_id_conflict} =
             Library.complete_command(library, "command-id", Digest.sha256("other"), :ok)

    assert {:error, :invalid_command_outcome} =
             Library.complete_command(library, "command-id", hash, {:error, "not-an-atom"})
  end

  test "readback is bounded and re-verifies the content address", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, imported} = Library.import_master(library, "verified bytes", master_attributes())
    digest = imported["digest"]

    assert {:error, :object_too_large} = Library.read_object(library, digest, 4)

    File.write!(ContentStore.object_path(data_dir, digest), "corrupt bytes", [:binary])
    assert {:error, :content_address_mismatch} = Library.read_object(library, digest)
  end

  test "startup repairs an interrupted move to trash without losing active content", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, imported} = Library.import_master(library, "repair me", master_attributes())
    digest = imported["digest"]
    GenServer.stop(library)

    :ok = ContentStore.move_to_trash(data_dir, digest)
    refute File.exists?(ContentStore.object_path(data_dir, digest))

    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)
    assert File.regular?(ContentStore.object_path(data_dir, digest))
    assert {:ok, %{"digest" => ^digest}} = Library.get_master(restarted, digest)
    GenServer.stop(restarted)
  end

  test "startup refuses metadata that points to missing content", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, imported} = Library.import_master(library, "missing", master_attributes())
    digest = imported["digest"]
    GenServer.stop(library)

    :ok = File.rm(ContentStore.object_path(data_dir, digest))

    assert {:error, {:object_missing, ^digest}} =
             Library.start_link(data_dir: data_dir, name: nil)
  end

  test "identical master bytes reuse the content-addressed object", %{library: library} do
    assert {:ok, first} = Library.import_master(library, "same bytes", master_attributes())
    assert {:ok, second} = Library.import_master(library, "same bytes", master_attributes())

    assert first["digest"] == second["digest"]
    assert second[:placement] == :existing
  end

  test "paired universal frame records survive restart and can be forgotten", %{
    library: library,
    data_dir: data_dir
  } do
    td_source = File.read!(@frame_fixture)

    assert {:ok, frame} =
             Library.register_paired_frame(
               library,
               td_source,
               "keychain:persistent-ref-0001",
               @frame_fingerprint
             )

    assert frame["frame_id"] == "sim-photo-00000001"
    assert frame["medium"] == "photo"
    assert frame["capabilities"]["stillOnly"]
    assert frame["credential_ref"] == "keychain:persistent-ref-0001"
    assert [%{"frame_id" => "sim-photo-00000001"}] = Library.list_paired_frames(library)

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, persisted} = Library.get_paired_frame(restarted, "sim-photo-00000001")
    assert persisted["server_spki_fingerprint"] == @frame_fingerprint

    assert :ok = Library.forget_paired_frame(restarted, "sim-photo-00000001")
    assert [] = Library.list_paired_frames(restarted)
    assert :not_found = Library.get_paired_frame(restarted, "sim-photo-00000001")

    GenServer.stop(restarted)
  end

  test "paired admission replays exactly and rejects silent identity rebinding", %{
    library: library
  } do
    td_source = File.read!(@frame_fixture)

    assert {:ok, frame} =
             Library.register_paired_frame(
               library,
               td_source,
               "keychain:persistent-ref-0001",
               @frame_fingerprint
             )

    assert {:ok, ^frame} =
             Library.register_paired_frame(
               library,
               td_source,
               "keychain:persistent-ref-0001",
               @frame_fingerprint
             )

    assert {:error, :paired_frame_conflict} =
             Library.register_paired_frame(
               library,
               td_source,
               "keychain:replacement-ref",
               @frame_fingerprint
             )

    assert {:error, :paired_frame_conflict} =
             Library.register_paired_frame(
               library,
               td_source,
               "keychain:persistent-ref-0001",
               "sha256:" <> String.duplicate("c", 64)
             )

    renamed_td =
      td_source
      |> Jason.decode!()
      |> Map.put("title", "Renamed frame")
      |> Jason.encode!()

    assert {:error, :paired_frame_conflict} =
             Library.register_paired_frame(
               library,
               renamed_td,
               "keychain:persistent-ref-0001",
               @frame_fingerprint
             )

    another_td =
      td_source
      |> Jason.decode!()
      |> Map.put("id", "urn:frameshift:device:another-frame-0001")
      |> Map.put("title", "Another frame")
      |> put_in(["frameshift:capabilities", "deviceId"], "another-frame-0001")
      |> Jason.encode!()

    assert {:error, :server_fingerprint_in_use} =
             Library.register_paired_frame(
               library,
               another_td,
               "keychain:another-frame",
               @frame_fingerprint
             )

    assert {:ok, ^frame} = Library.get_paired_frame(library, frame["frame_id"])

    assert %{"entries" => audit} = Library.audit_page(library)
    assert Enum.count(audit, &(&1["operation"] == "frame.paired")) == 1
  end

  test "canonical recipes ignore map insertion order and preserve source order", %{
    library: library
  } do
    {:ok, source} = Library.import_master(library, "source", master_attributes())

    first = %{"crop" => [0, 0, 10, 10], "profile" => "paper-v1"}
    second = Map.new(Enum.reverse(Map.to_list(first)))

    assert {:ok, first_hash} =
             Library.register_recipe(library, :composition, first, [source["digest"]])

    assert {:ok, second_hash} =
             Library.register_recipe(library, :composition, second, [source["digest"]])

    assert first_hash == second_hash

    assert {:ok, different_hash} =
             Library.register_recipe(library, :composition, first, [])

    refute first_hash == different_hash

    missing_source = "sha256:" <> String.duplicate("f", 64)

    assert {:error, :source_missing} =
             Library.register_recipe(library, :composition, first, [missing_source])
  end

  test "generated variants keep immutable parent and generation recipe relationships", %{
    library: library
  } do
    {:ok, parent} = Library.import_master(library, "parent", master_attributes())

    assert {:ok, recipe_hash} =
             Library.register_recipe(
               library,
               :generation,
               %{"provider" => "fixture", "seed" => 7},
               [parent["digest"]]
             )

    attributes = master_attributes(%{title: "Variant", source_kind: :generated})

    assert {:ok, variant} =
             Library.add_generated_variant(
               library,
               "variant",
               attributes,
               parent["digest"],
               recipe_hash
             )

    assert variant["parent_digest"] == parent["digest"]
    assert variant["generation_recipe_hash"] == recipe_hash

    assert {:error, :parent_or_recipe_missing} =
             Library.add_generated_variant(
               library,
               "orphan",
               attributes,
               "sha256:" <> String.duplicate("0", 64),
               recipe_hash
             )
  end

  test "artifact registration returns a deterministic cache hit", %{library: library} do
    {:ok, master} = Library.import_master(library, "master", master_attributes())

    {:ok, recipe_hash} =
      Library.register_recipe(
        library,
        :composition,
        %{"width" => 2, "height" => 1},
        [master["digest"]]
      )

    attributes = %{
      master_digest: master["digest"],
      recipe_hash: recipe_hash,
      profile_id: "urn:frameshift:test:rgb24",
      renderer_revision: "test-renderer-v1",
      media_type: "application/vnd.frameshift.rgb24"
    }

    assert {:ok, first} = Library.register_artifact(library, <<0, 1, 2, 3, 4, 5>>, attributes)
    assert first[:cache] == :miss

    assert {:ok, second} =
             Library.register_artifact(library, "different ignored bytes", attributes)

    assert second[:cache] == :hit
    assert second["digest"] == first["digest"]
  end

  test "distinct recipes share identical artifact bytes and survive restart", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, first_master} = Library.import_master(library, "first master", master_attributes())
    {:ok, second_master} = Library.import_master(library, "second master", master_attributes())

    {:ok, first_recipe} =
      Library.register_recipe(library, :composition, %{"crop" => "left"}, [
        first_master["digest"]
      ])

    {:ok, second_recipe} =
      Library.register_recipe(library, :composition, %{"crop" => "right"}, [
        second_master["digest"]
      ])

    attributes = %{
      profile_id: "urn:frameshift:test:rgb24",
      renderer_revision: "test-renderer-v1",
      media_type: "application/vnd.frameshift.rgb24"
    }

    first_attributes =
      Map.merge(attributes, %{master_digest: first_master["digest"], recipe_hash: first_recipe})

    second_attributes =
      Map.merge(attributes, %{master_digest: second_master["digest"], recipe_hash: second_recipe})

    bytes = <<0, 1, 2, 3, 4, 5>>

    assert {:ok, first} = Library.register_artifact(library, bytes, first_attributes)
    assert {:ok, second} = Library.register_artifact(library, bytes, second_attributes)
    assert first[:cache] == :miss
    assert second[:cache] == :miss
    assert first["digest"] == second["digest"]
    assert first["master_digest"] == first_master["digest"]
    assert second["master_digest"] == second_master["digest"]

    assert {:error, :cache_identity_conflict} =
             Library.register_artifact(
               library,
               bytes,
               %{first_attributes | media_type: "application/octet-stream"}
             )

    {:ok, third_recipe} =
      Library.register_recipe(library, :composition, %{"crop" => "center"}, [
        first_master["digest"]
      ])

    assert {:error, :artifact_media_type_conflict} =
             Library.register_artifact(
               library,
               bytes,
               %{
                 first_attributes
                 | recipe_hash: third_recipe,
                   media_type: "application/octet-stream"
               }
             )

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, %{"digest" => digest, "master_digest" => first_digest}} =
             Library.cached_artifact(
               restarted,
               first_recipe,
               attributes.profile_id,
               attributes.renderer_revision
             )

    assert digest == first["digest"]
    assert first_digest == first_master["digest"]

    assert {:ok, %{"digest" => ^digest, "master_digest" => second_digest}} =
             Library.cached_artifact(
               restarted,
               second_recipe,
               attributes.profile_id,
               attributes.renderer_revision
             )

    assert second_digest == second_master["digest"]
    assert {:ok, %{"bytes" => ^bytes}} = Library.read_object(restarted, digest)

    GenServer.stop(restarted)
  end

  test "artifact recipe links are backfilled when an existing library upgrades", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, master} = Library.import_master(library, "existing master", master_attributes())

    {:ok, recipe_hash} =
      Library.register_recipe(library, :composition, %{"crop" => "full"}, [master["digest"]])

    attributes = %{
      master_digest: master["digest"],
      recipe_hash: recipe_hash,
      profile_id: "urn:frameshift:test:rgb24",
      renderer_revision: "test-renderer-v1",
      media_type: "application/vnd.frameshift.rgb24"
    }

    assert {:ok, artifact} = Library.register_artifact(library, <<1, 2, 3>>, attributes)
    GenServer.stop(library)

    {:ok, database} = Exqlite.start_link(database: Path.join(data_dir, "metadata.sqlite"))
    Exqlite.query!(database, "DROP TABLE artifact_recipe_links")
    Exqlite.query!(database, "DELETE FROM schema_migrations WHERE version = 13")
    GenServer.stop(database)

    {:ok, upgraded} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, %{"digest" => digest, "master_digest" => master_digest}} =
             Library.cached_artifact(
               upgraded,
               recipe_hash,
               attributes.profile_id,
               attributes.renderer_revision
             )

    assert digest == artifact["digest"]
    assert master_digest == master["digest"]
    GenServer.stop(upgraded)
  end

  test "remove is recoverable and collection never deletes protected content", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, master} = Library.import_master(library, "protected", master_attributes())
    digest = master["digest"]

    assert :ok = Library.pin(library, digest)
    assert :ok = Library.remove_master(library, digest)
    assert {:ok, []} = Library.collect_removed(library)
    assert File.regular?(ContentStore.object_path(data_dir, digest))

    assert :ok = Library.unpin(library, digest)
    assert {:ok, [^digest]} = Library.collect_removed(library)
    refute File.exists?(ContentStore.object_path(data_dir, digest))
    assert File.regular?(ContentStore.trash_path(data_dir, digest))

    assert :ok = Library.restore_master(library, digest)
    assert File.regular?(ContentStore.object_path(data_dir, digest))
    refute File.exists?(ContentStore.trash_path(data_dir, digest))
    assert [%{"digest" => ^digest}] = Library.search(library, "Morning")
  end

  test "recipe and frame references protect removed masters", %{library: library} do
    {:ok, recipe_source} = Library.import_master(library, "recipe source", master_attributes())

    assert {:ok, _} =
             Library.register_recipe(
               library,
               :composition,
               %{"profile" => "fixture"},
               [recipe_source["digest"]]
             )

    :ok = Library.remove_master(library, recipe_source["digest"])
    assert {:ok, []} = Library.collect_removed(library)

    {:ok, frame_source} =
      Library.import_master(library, "frame source", master_attributes(%{title: "Frame Source"}))

    :ok = Library.protect_frame_asset(library, "frame-1", "current", frame_source["digest"])
    :ok = Library.remove_master(library, frame_source["digest"])
    assert {:ok, []} = Library.collect_removed(library)

    :ok = Library.release_frame_asset(library, "frame-1", "current", frame_source["digest"])
    assert {:ok, [digest]} = Library.collect_removed(library)
    assert digest == frame_source["digest"]
  end

  test "search covers titles and labels while user labels remain independent", %{library: library} do
    {:ok, forest} =
      Library.import_master(library, "forest", master_attributes(%{title: "Untitled Study"}))

    :ok = Library.add_label(library, forest["digest"], "forest", :vision, 0.87, "vision-v1")
    :ok = Library.add_label(library, forest["digest"], "quiet", :user)
    :ok = Library.pin(library, forest["digest"])

    assert [%{"digest" => digest, "pinned" => true}] = Library.search(library, "forest")
    assert digest == forest["digest"]
    assert [%{"digest" => ^digest}] = Library.search(library, "quiet", pinned: true)

    assert [] =
             Library.search(library, "quiet", pinned: false, limit: 1)
             |> Enum.reject(& &1["pinned"])
  end

  test "FTS search treats operators as text and follows remove and restore", %{library: library} do
    {:ok, master} =
      Library.import_master(library, "cafe image", master_attributes(%{title: "Café Study"}))

    digest = master["digest"]
    :ok = Library.add_label(library, digest, "blue-forest", :user)

    assert [%{"digest" => ^digest}] = Library.search(library, "cafe")
    assert [%{"digest" => ^digest}] = Library.search(library, "blu for")
    assert [] = Library.search(library, "OR")
    assert [] = Library.search(library, "%")
    assert [] = Library.search(library, String.duplicate("a", 513))
    assert [] = Library.search(library, String.duplicate("word ", 9))
    assert [] = Library.search(library, String.duplicate("a", 33))

    :ok = Library.remove_master(library, digest)
    assert [] = Library.search(library, "cafe")
    assert [] = Library.search(library, "blue")

    :ok = Library.restore_master(library, digest)
    assert [%{"digest" => ^digest}] = Library.search(library, "blue")
  end

  test "FTS index backfills titles and labels when an existing library upgrades", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, master} =
      Library.import_master(library, "indexed image", master_attributes(%{title: "Old Portrait"}))

    digest = master["digest"]
    :ok = Library.add_label(library, digest, "copper", :user)
    GenServer.stop(library)

    {:ok, database} = Exqlite.start_link(database: Path.join(data_dir, "metadata.sqlite"))

    for trigger <-
          ~w(master_search_insert master_search_update master_search_delete
                      master_search_label_insert master_search_label_update master_search_label_delete) do
      Exqlite.query!(database, "DROP TRIGGER #{trigger}")
    end

    Exqlite.query!(database, "DROP TABLE master_search")
    Exqlite.query!(database, "DELETE FROM schema_migrations WHERE version = 15")
    GenServer.stop(database)

    {:ok, upgraded} = Library.start_link(data_dir: data_dir, name: nil)
    assert [%{"digest" => ^digest}] = Library.search(upgraded, "copp")
    assert [%{"digest" => ^digest}] = Library.search(upgraded, "portr")
    GenServer.stop(upgraded)
  end

  test "a missing search projection can be rebuilt without changing library state", %{
    library: library,
    data_dir: data_dir
  } do
    {:ok, master} =
      Library.import_master(library, "rebuild image", master_attributes(%{title: "Copper Study"}))

    digest = master["digest"]
    :ok = Library.add_label(library, digest, "forest", :user)
    :ok = Library.pin(library, digest)
    GenServer.stop(library)

    {:ok, database} = Exqlite.start_link(database: Path.join(data_dir, "metadata.sqlite"))
    Exqlite.query!(database, "DELETE FROM master_search")
    GenServer.stop(database)

    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)
    assert [] = Library.search(restarted, "forest")

    assert :ok = Library.rebuild_search_index(restarted)
    assert [%{"digest" => ^digest, "pinned" => true}] = Library.search(restarted, "forest")
    assert [%{"digest" => ^digest}] = Library.search(restarted, "copp")
    GenServer.stop(restarted)
  end

  defp master_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Morning Study",
        source_kind: :import,
        width: 640,
        height: 480,
        media_type: "image/png",
        provenance: %{"kind" => "local-import"}
      },
      overrides
    )
  end
end
