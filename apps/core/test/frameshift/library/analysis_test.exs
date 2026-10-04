defmodule Frameshift.Library.AnalysisTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Library.Backup
  alias Frameshift.LocalAPI

  @cohort "apple-vision-v1:c2:f2:macos27.0.1:arm64:source256-fit"

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-analysis-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, library} = Library.start_link(data_dir: Path.join(root, "live"), name: nil)
    {:ok, master} = Library.import_master(library, "unchanged artwork", attributes())
    %{library: library, root: root, digest: master["digest"]}
  end

  test "transaction preserves user work and byte custody, replacing only Vision observations",
       c do
    :ok = Library.add_label(c.library, c.digest, "my label", :user)
    :ok = Library.add_label(c.library, c.digest, "filename term", :filename)
    :ok = Library.add_label(c.library, c.digest, "old observation", :vision, 0.7, "old")
    :ok = Library.pin(c.library, c.digest)
    :ok = Library.protect_frame_asset(c.library, "frame", "current", c.digest)
    {:ok, before} = Library.metadata(c.library, c.digest)
    command = command(c.digest, before["revision"])
    assert {:ok, snapshot} = LocalAPI.execute(c.library, command)
    metadata = snapshot["updatedMetadata"]
    assert metadata["title"] == before["title"]
    assert metadata["revision"] != before["revision"]
    assert Enum.count(metadata["labels"], &(&1["provenance"] == "vision")) == 1
    assert Enum.any?(metadata["labels"], &(&1["label"] == "my label"))
    assert Enum.any?(metadata["labels"], &(&1["label"] == "filename term"))
    assert length(Library.search(c.library, "forest")) == 1
    assert Library.search(c.library, "old observation") == []
    assert {:ok, %{"bytes" => "unchanged artwork"}} = Library.read_object(c.library, c.digest)
    assert {:ok, analysis} = Library.analysis(c.library, c.digest)
    assert analysis["inputDigest"] == command["inputDigest"]
    assert analysis["featurePrint"]["archive"] == Base.encode64(archive())
    assert analysis["featurePrint"]["digest"] == Digest.sha256(archive())

    assert {:ok, %{"itemIDs" => [], "hasMore" => false}} =
             Library.analysis_pending(c.library, @cohort)

    assert %{"entries" => entries} = Library.audit_page(c.library)
    assert Enum.find(entries, &(&1["operation"] == "master.vision-recorded"))["detail"] == %{}
    :ok = Library.remove_master(c.library, c.digest)
    assert {:error, :item_not_found} = Library.analysis(c.library, c.digest)
    assert {:ok, []} = Library.collect_removed(c.library)

    assert {:ok, %{"items" => [%{"retentionReasons" => ["pinned", "frame"]}]}} =
             Library.recovery_page(c.library)
  end

  test "maximum archive and empty classifications survive restart and verified backup/restore",
       c do
    {:ok, before} = Library.metadata(c.library, c.digest)
    bytes = :binary.copy(<<0, 255>>, 8192)
    command = command(c.digest, before["revision"], bytes) |> Map.put("visionLabels", [])
    assert {:ok, _} = Library.record_vision(c.library, c.digest, command)
    assert {:ok, observed} = Library.analysis(c.library, c.digest)
    backup = Path.join(c.root, "backup")
    restored = Path.join(c.root, "restored")
    assert :ok = Library.create_backup(c.library, backup)
    assert :ok = Backup.verify(backup)
    assert :ok = Backup.restore(backup, restored)
    GenServer.stop(c.library)
    {:ok, restarted} = Library.start_link(data_dir: Path.join(c.root, "live"), name: nil)
    {:ok, copy} = Library.start_link(data_dir: restored, name: nil)

    for library <- [restarted, copy] do
      assert {:ok, ^observed} = Library.analysis(library, c.digest)
      assert {:ok, %{"itemIDs" => []}} = Library.analysis_pending(library, @cohort)
      assert {:ok, ^before} = Library.metadata(library, c.digest)
      GenServer.stop(library)
    end
  end

  test "stale, removed, unknown and bounded malformed commands refuse without persistence", c do
    {:ok, before} = Library.metadata(c.library, c.digest)
    valid = command(c.digest, before["revision"])
    label = hd(valid["visionLabels"])

    for change <- [
          %{"cohort" => "unversioned"},
          %{"inputDigest" => "bad"},
          %{"rendererBuildDigest" => "bad"},
          %{"featureDigest" => Digest.sha256("different")},
          %{"featureArchiveChunks" => []},
          %{"featureArchiveChunks" => [Base.encode64(:binary.copy("a", 6145))]},
          %{"featureArchiveChunks" => ["YQ==", "Yg=="]},
          %{"featureArchiveChunks" => ["YQ==\n"]},
          %{
            "featureArchiveChunks" =>
              Enum.map(1..3, fn _ -> Base.encode64(:binary.copy("a", 6144)) end)
          },
          %{"visionLabels" => [label, Map.put(label, "label", "FOREST")]},
          %{"visionLabels" => [Map.put(label, "confidence", 0.49)]},
          %{"visionLabels" => [Map.put(label, "provenance", "user")]},
          %{"visionLabels" => [Map.put(label, "revision", "old")]},
          %{"visionLabels" => [Map.put(label, "label", "line\nbreak")]},
          %{"visionLabels" => [Map.put(label, "extra", true)]},
          %{"visionLabels" => Enum.map(1..33, &Map.put(label, "label", "label#{&1}"))}
        ] do
      assert {:error, :invalid_analysis} =
               Library.record_vision(c.library, c.digest, Map.merge(valid, change))
    end

    assert {:error, :invalid_command} =
             LocalAPI.execute(c.library, Map.put(valid, "pixels", "forged"))

    assert {:ok, ^before} = Library.metadata(c.library, c.digest)
    assert {:error, :analysis_unavailable} = Library.analysis(c.library, c.digest)
    :ok = Library.add_label(c.library, c.digest, "new user label", :user)

    assert {:error, :metadata_revision_conflict} =
             Library.record_vision(c.library, c.digest, valid)

    :ok = Library.remove_master(c.library, c.digest)
    assert {:error, :item_not_found} = Library.record_vision(c.library, c.digest, valid)

    assert {:error, :item_not_found} =
             Library.record_vision(c.library, Digest.sha256("missing"), valid)
  end

  test "combined count and rejected audit roll back labels, FTS and the previous archive", c do
    for i <- 1..64, do: :ok = Library.add_label(c.library, c.digest, "metadata#{i}", :metadata)
    {:ok, before} = Library.metadata(c.library, c.digest)

    assert {:error, :invalid_analysis} =
             Library.record_vision(c.library, c.digest, command(c.digest, before["revision"]))

    empty = command(c.digest, before["revision"]) |> Map.put("visionLabels", [])
    assert {:ok, _} = Library.record_vision(c.library, c.digest, empty)
    {:ok, database} = Exqlite.start_link(database: Path.join([c.root, "live", "metadata.sqlite"]))

    Exqlite.query!(
      database,
      "DELETE FROM labels WHERE master_digest = ? AND label = 'metadata64'",
      [c.digest]
    )

    {:ok, room} = Library.metadata(c.library, c.digest)

    assert {:ok, before} =
             Library.record_vision(c.library, c.digest, command(c.digest, room["revision"]))

    assert {:ok, previous} = Library.analysis(c.library, c.digest)

    Exqlite.query!(
      database,
      "CREATE TRIGGER reject_vision_audit BEFORE INSERT ON audit_entries WHEN NEW.operation = 'master.vision-recorded' BEGIN SELECT RAISE(ABORT, 'fixture refusal'); END"
    )

    different =
      command(c.digest, before["revision"], "different archive")
      |> Map.put("visionLabels", [
        %{
          "label" => "rejected",
          "provenance" => "vision",
          "confidence" => 0.8,
          "revision" => @cohort
        }
      ])

    assert {:error, {:database, _}} = Library.record_vision(c.library, c.digest, different)
    assert {:ok, ^before} = Library.metadata(c.library, c.digest)
    assert {:ok, ^previous} = Library.analysis(c.library, c.digest)
    assert length(Library.search(c.library, "forest")) == 1
    assert Library.search(c.library, "rejected") == []

    Exqlite.query!(
      database,
      "UPDATE master_analysis SET feature_archive = ? WHERE master_digest = ?",
      [{:blob, "corrupt"}, c.digest]
    )

    assert {:error, :analysis_unavailable} = Library.analysis(c.library, c.digest)
    GenServer.stop(database)
  end

  test "pending pages exclude removed and current cohort, with sixteen IDs and finite overflow",
       c do
    for i <- 1..18, do: Library.import_master(c.library, "pending#{i}", attributes())

    assert {:ok, %{"itemIDs" => ids, "hasMore" => true}} =
             Library.analysis_pending(c.library, @cohort)

    assert length(ids) == 16
    assert ids == Enum.sort(Enum.uniq(ids))
    {:ok, before} = Library.metadata(c.library, c.digest)

    assert {:ok, _} =
             Library.record_vision(c.library, c.digest, command(c.digest, before["revision"]))

    for digest <- Enum.take(Enum.reject(ids, &(&1 == c.digest)), 4),
        do: Library.remove_master(c.library, digest)

    assert {:ok, %{"itemIDs" => remaining, "hasMore" => false}} =
             Library.analysis_pending(c.library, @cohort)

    assert length(remaining) == 14
    refute c.digest in remaining

    assert {:ok, %{"itemIDs" => other, "hasMore" => false}} =
             Library.analysis_pending(c.library, String.replace(@cohort, "27.0.1", "27.0.2"))

    assert c.digest in other
    assert {:error, :invalid_request} = Library.analysis_pending(c.library, "unversioned")
  end

  defp attributes do
    %{
      title: "Original",
      source_kind: :import,
      width: 2,
      height: 1,
      media_type: "image/png",
      provenance: %{"kind" => "local-import"}
    }
  end

  defp archive, do: <<0, 255, 1, 128, 2>>

  defp command(digest, revision, bytes \\ archive()) do
    %{
      "id" => "analysis-command",
      "kind" => "recordVision",
      "itemID" => digest,
      "metadataRevision" => revision,
      "cohort" => @cohort,
      "inputDigest" => Digest.sha256("preview"),
      "rendererBuildDigest" => Digest.sha256("renderer"),
      "visionLabels" => [
        %{
          "label" => "forest",
          "provenance" => "vision",
          "confidence" => 0.8,
          "revision" => @cohort
        }
      ],
      "featureArchiveChunks" =>
        for(<<chunk::binary-size(6144) <- bytes>>, do: Base.encode64(chunk)) ++ tail(bytes),
      "featureDigest" => Digest.sha256(bytes)
    }
  end

  defp tail(bytes) do
    size = rem(byte_size(bytes), 6144)
    if size == 0, do: [], else: [Base.encode64(binary_part(bytes, byte_size(bytes) - size, size))]
  end
end
