defmodule Frameshift.Library.MetadataTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.ContentStore
  alias Frameshift.Library
  alias Frameshift.LocalAPI

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-metadata-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, library} = Library.start_link(data_dir: root, name: nil)
    {:ok, master} = Library.import_master(library, "retained bytes", attributes("Original"))
    %{library: library, root: root, digest: master["digest"]}
  end

  test "title/user corrections preserve machine provenance, identity and frame references", c do
    :ok = Library.add_label(c.library, c.digest, "forest", :vision, 0.8, "vision-1")
    :ok = Library.add_label(c.library, c.digest, "wrong", :filename)
    :ok = Library.add_label(c.library, c.digest, "old", :user)
    :ok = Library.pin(c.library, c.digest)
    :ok = Library.protect_frame_asset(c.library, "frame", "current", c.digest)
    {:ok, before} = Library.metadata(c.library, c.digest)

    command =
      edit(c.digest, before["revision"], %{
        "title" => "  New Study  ",
        "userLabels" => ["  Quiet  ", "QUIET", "Cafe\u0301"],
        "dismissedLabels" => [%{"label" => "wrong", "provenance" => "filename"}]
      })

    assert {:ok, snapshot} = LocalAPI.execute(c.library, command)
    after_edit = snapshot["updatedMetadata"]
    assert after_edit["itemID"] == c.digest
    assert after_edit["title"] == "New Study"
    assert after_edit["revision"] != before["revision"]

    assert Enum.find(after_edit["labels"], &(&1["label"] == "forest")) ==
             %{
               "label" => "forest",
               "provenance" => "vision",
               "confidence" => 0.8,
               "revision" => "vision-1"
             }

    assert Enum.filter(after_edit["labels"], &(&1["provenance"] == "user"))
           |> Enum.map(& &1["label"]) == ["Café", "Quiet"]

    assert [%{"digest" => digest, "pinned" => true}] = Library.search(c.library, "quiet")
    assert digest == c.digest
    assert Library.search(c.library, "old") == []
    assert {:ok, %{"bytes" => "retained bytes"}} = Library.read_object(c.library, c.digest)
    :ok = Library.remove_master(c.library, c.digest)
    assert {:ok, []} = Library.collect_removed(c.library)

    assert {:ok, %{"items" => [%{"retentionReasons" => ["pinned", "frame"]}]}} =
             Library.recovery_page(c.library)

    assert %{"entries" => entries} = Library.audit_page(c.library)
    audit = Enum.find(entries, &(&1["operation"] == "master.metadata-updated"))
    assert audit["detail"] == %{}
  end

  test "machine observations invalidate drafts; removed masters refuse metadata writes", c do
    {:ok, before} = Library.metadata(c.library, c.digest)
    :ok = Library.add_label(c.library, c.digest, "new observation", :metadata)

    assert {:error, :metadata_revision_conflict} =
             Library.update_metadata(c.library, c.digest, edit(c.digest, before["revision"]))

    {:ok, current} = Library.metadata(c.library, c.digest)
    :ok = Library.remove_master(c.library, c.digest)

    assert {:error, :item_not_found} =
             Library.update_metadata(c.library, c.digest, edit(c.digest, current["revision"]))

    assert Library.search(c.library, "Original") == []
  end

  test "input bounds and forged dismissals refuse without changing the revision", c do
    {:ok, before} = Library.metadata(c.library, c.digest)

    for change <- [
          %{"title" => String.duplicate("é", 129)},
          %{"title" => "\n"},
          %{"userLabels" => [String.duplicate("é", 65)]},
          %{"userLabels" => ["a\u0000b"]},
          %{"userLabels" => Enum.map(1..33, &"label-#{&1}")},
          %{"dismissedLabels" => [%{"label" => "absent", "provenance" => "vision"}]},
          %{"dismissedLabels" => [%{"label" => "absent", "provenance" => "user"}]}
        ] do
      assert {:error, :invalid_metadata} =
               Library.update_metadata(
                 c.library,
                 c.digest,
                 edit(c.digest, before["revision"], change)
               )
    end

    assert {:ok, ^before} = Library.metadata(c.library, c.digest)
    assert {:error, :invalid_label} = Library.add_label(c.library, c.digest, <<255>>, :user)

    assert {:error, :invalid_label} =
             Library.add_label(
               c.library,
               c.digest,
               "label",
               :vision,
               nil,
               String.duplicate("x", 129)
             )

    for i <- 1..64,
        do: assert(:ok == Library.add_label(c.library, c.digest, "machine-#{i}", :vision))

    assert {:error, :label_limit} = Library.add_label(c.library, c.digest, "overflow", :vision)
    assert :ok = Library.add_label(c.library, c.digest, "MACHINE-1", :vision, 0.9)
  end

  test "metadata and FTS/audit roll back together on a database rejection", c do
    {:ok, before} = Library.metadata(c.library, c.digest)
    database = database(c.root)

    Exqlite.query!(
      database,
      "CREATE TRIGGER reject_metadata_audit BEFORE INSERT ON audit_entries WHEN NEW.operation = 'master.metadata-updated' BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END"
    )

    assert {:error, {:database, _}} =
             Library.update_metadata(
               c.library,
               c.digest,
               edit(c.digest, before["revision"], %{
                 "title" => "Rejected",
                 "userLabels" => ["hidden"]
               })
             )

    assert {:ok, ^before} = Library.metadata(c.library, c.digest)
    assert Library.search(c.library, "hidden") == []
    assert Library.search(c.library, "Rejected") == []
    assert length(Library.search(c.library, "Original")) == 1
    GenServer.stop(database)
  end

  test "recovery pagination reaches all removed masters without collecting protected bytes", c do
    for i <- 1..52 do
      {:ok, master} = Library.import_master(c.library, "page-#{i}", attributes("Page #{i}"))
      :ok = Library.remove_master(c.library, master["digest"])
    end

    :ok = Library.remove_master(c.library, c.digest)
    {:ok, first} = Library.recovery_page(c.library)
    assert length(first["items"]) == 50
    {:ok, second} = Library.recovery_page(c.library, first["nextCursor"])
    assert length(second["items"]) == 3
    assert second["nextCursor"] == nil
    ids = Enum.map(first["items"] ++ second["items"], & &1["id"])
    assert ids == Enum.sort(Enum.uniq(ids))
    assert {:error, :invalid_request} = Library.recovery_page(c.library, "../../")
  end

  test "restore verifies bytes and atomically restores metadata with interrupted move recovery",
       c do
    :ok = Library.remove_master(c.library, c.digest)
    assert {:ok, [digest]} = Library.collect_removed(c.library)
    assert digest == c.digest
    database = database(c.root)

    Exqlite.query!(
      database,
      "CREATE TRIGGER reject_restore BEFORE UPDATE OF storage_state ON objects WHEN NEW.storage_state = 'active' BEGIN SELECT RAISE(ABORT, 'fixture restore failure'); END"
    )

    assert {:error, {:database, _}} = Library.restore_master(c.library, c.digest)
    {:ok, still_removed} = Library.get_master(c.library, c.digest)
    assert still_removed["removed_at_ms"] != nil
    assert still_removed["storage_state"] == "trash"
    assert File.regular?(ContentStore.trash_path(c.root, c.digest))
    Exqlite.query!(database, "DROP TRIGGER reject_restore")
    GenServer.stop(database)
    :ok = ContentStore.restore(c.root, c.digest)
    GenServer.stop(c.library)
    {:ok, restarted} = Library.start_link(data_dir: c.root, name: nil)
    assert File.regular?(ContentStore.trash_path(c.root, c.digest))
    assert :ok = Library.restore_master(restarted, c.digest)
    assert :ok = Library.restore_master(restarted, c.digest)
    assert length(Library.search(restarted, "Original")) == 1
    assert {:ok, %{"bytes" => "retained bytes"}} = Library.read_object(restarted, c.digest)
    GenServer.stop(restarted)
  end

  test "corrupt or absent retained bytes cannot be activated by restore", c do
    :ok = Library.remove_master(c.library, c.digest)
    File.write!(ContentStore.object_path(c.root, c.digest), "corrupted")

    assert {:error, :restore_failed} =
             LocalAPI.execute(c.library, %{"kind" => "restore", "itemID" => c.digest})

    assert {:ok, %{"removed_at_ms" => removed}} = Library.get_master(c.library, c.digest)
    assert removed != nil
    File.rm!(ContentStore.object_path(c.root, c.digest))

    assert {:error, :restore_failed} =
             LocalAPI.execute(c.library, %{"kind" => "restore", "itemID" => c.digest})

    assert Library.search(c.library, "Original") == []
  end

  defp database(root) do
    {:ok, database} = Exqlite.start_link(database: Path.join(root, "metadata.sqlite"))
    database
  end

  defp edit(digest, revision, changes \\ %{}) do
    Map.merge(
      %{
        "kind" => "updateMetadata",
        "itemID" => digest,
        "metadataRevision" => revision,
        "title" => "Changed",
        "userLabels" => [],
        "dismissedLabels" => []
      },
      changes
    )
  end

  defp attributes(title),
    do: %{
      title: title,
      source_kind: :import,
      width: 2,
      height: 1,
      media_type: "image/png",
      provenance: %{"kind" => "local-import"}
    }
end
