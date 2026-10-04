defmodule Frameshift.Library.SimilarityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalAPI

  @cohort "apple-vision-v1:c2:f2:macos27.0.1:arm64:source256-fit"
  @archive :binary.copy(<<0, 255>>, 8192)
  @thing File.read!(
           Path.expand("../../../../../protocol/fixtures/valid/thing-description.json", __DIR__)
         )

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-similarity-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, library} = Library.start_link(data_dir: root, name: nil)
    source = observed(library, "source")
    candidates = Enum.map(1..19, &observed(library, "candidate#{&1}")) |> Enum.sort()
    %{library: library, root: root, source: source, candidates: candidates}
  end

  test "pages verify exact source, ordering, maximum archives and read-only state", c do
    before = LocalAPI.snapshot(c.library)
    audit = Library.audit_page(c.library)
    assert {:ok, first} = Library.similarity_candidates(c.library, request(c.source))
    assert ids(first) == Enum.take(c.candidates, 16)
    assert first["nextCursor"] == List.last(ids(first))
    assert byte_size(Jason.encode!(first)) < 1024 * 1024
    assert Enum.all?(first["items"], &(Base.decode64!(&1["featurePrint"]["archive"]) == @archive))

    assert {:ok, second} =
             Library.similarity_candidates(
               c.library,
               Map.put(request(c.source), "afterID", first["nextCursor"])
             )

    assert ids(second) == Enum.drop(c.candidates, 16)
    assert second["nextCursor"] == nil
    refute c.source in (ids(first) ++ ids(second))
    assert Library.audit_page(c.library) == audit
    assert LocalAPI.snapshot(c.library) == before
  end

  test "pin/source/frame facets intersect before limits using retained artifact custody", c do
    selected = List.last(c.candidates)
    :ok = Library.pin(c.library, selected)

    assert {:ok, pinned} =
             Library.similarity_candidates(
               c.library,
               request(c.source, %{"pinnedOnly" => true, "sourceKind" => "import"})
             )

    assert ids(pinned) == [selected]
    assert pinned["items"] |> hd() |> get_in(["item", "isPinned"]) == true

    {:ok, recipe} =
      Library.register_recipe(
        c.library,
        :generation,
        %{"provider" => "fixture", "prompt" => "synthetic"},
        [c.source]
      )

    {:ok, variant} =
      Library.add_generated_variant(
        c.library,
        "generated",
        attributes("Generated"),
        c.source,
        recipe
      )

    generated = variant["digest"]
    record(c.library, generated)

    {:ok, frame} =
      Library.register_paired_frame(
        c.library,
        @thing,
        "keychain:similarity-frame",
        Digest.sha256("frame")
      )

    :ok = Library.protect_frame_asset(c.library, frame["frame_id"], "current", selected)

    {:ok, render_recipe} =
      Library.register_recipe(c.library, :composition, %{"crop" => [0, 0, 2, 1]}, [generated])

    {:ok, artifact} =
      Library.register_artifact(c.library, "rendered", %{
        master_digest: generated,
        recipe_hash: render_recipe,
        profile_id: "fixture",
        renderer_revision: "fixture-1",
        media_type: "application/octet-stream"
      })

    :ok =
      Library.protect_frame_asset(c.library, frame["frame_id"], "playlist", artifact["digest"])

    assert {:ok, members} =
             Library.similarity_candidates(
               c.library,
               request(c.source, %{"frameID" => frame["frame_id"]})
             )

    assert ids(members) == Enum.sort([selected, generated])

    assert {:ok, only_generated} =
             Library.similarity_candidates(
               c.library,
               request(c.source, %{"sourceKind" => "generated", "frameID" => frame["frame_id"]})
             )

    assert ids(only_generated) == [generated]
    :ok = Library.remove_master(c.library, generated)

    assert {:ok, removed} =
             Library.similarity_candidates(
               c.library,
               request(c.source, %{"frameID" => frame["frame_id"]})
             )

    assert ids(removed) == [selected]
  end

  test "changed/removed source and malformed scope refuse instead of hiding candidates", c do
    for changes <- [
          %{"itemID" => "path"},
          %{"featureDigest" => "mutable"},
          %{"cohort" => "mutable"},
          %{"afterID" => "path"},
          %{"filters" => %{"sourceKind" => "other"}},
          %{"filters" => %{"pinnedOnly" => 1}},
          %{"filters" => %{"frameID" => "unpaired"}},
          %{"filters" => %{"query" => "text"}},
          %{"filters" => nil}
        ] do
      assert {:error, :invalid_request} =
               Library.similarity_candidates(c.library, Map.merge(request(c.source), changes))
    end

    assert {:error, :analysis_changed} =
             Library.similarity_candidates(
               c.library,
               Map.put(request(c.source), "featureDigest", Digest.sha256("different"))
             )

    {:ok, current} = Library.metadata(c.library, c.source)

    assert {:ok, _} =
             Library.record_vision(
               c.library,
               c.source,
               command(c.source, current["revision"], "replacement")
             )

    assert {:error, :analysis_changed} =
             Library.similarity_candidates(c.library, request(c.source))

    :ok = Library.remove_master(c.library, c.source)
    assert {:error, :item_not_found} = Library.similarity_candidates(c.library, request(c.source))
  end

  test "corrupt candidate refuses a page and a different cohort is excluded", c do
    [first | _] = c.candidates
    {:ok, database} = Exqlite.start_link(database: Path.join(c.root, "metadata.sqlite"))

    Exqlite.query!(database, "UPDATE master_analysis SET cohort = ? WHERE master_digest = ?", [
      String.replace(@cohort, "27.0.1", "27.0.2"),
      first
    ])

    assert {:ok, page} = Library.similarity_candidates(c.library, request(c.source))
    refute first in ids(page)

    Exqlite.query!(
      database,
      "UPDATE master_analysis SET cohort = ?, feature_archive = ? WHERE master_digest = ?",
      [@cohort, {:blob, "corrupt"}, first]
    )

    assert {:error, :analysis_unavailable} =
             Library.similarity_candidates(c.library, request(c.source))

    GenServer.stop(database)
  end

  defp ids(page), do: Enum.map(page["items"], & &1["item"]["id"])

  defp request(source, filters \\ %{}),
    do: %{
      "itemID" => source,
      "cohort" => @cohort,
      "featureDigest" => Digest.sha256(@archive),
      "filters" => filters
    }

  defp observed(library, text) do
    {:ok, master} = Library.import_master(library, text, attributes(text))
    record(library, master["digest"])
    master["digest"]
  end

  defp record(library, digest) do
    {:ok, metadata} = Library.metadata(library, digest)

    {:ok, _} =
      Library.record_vision(library, digest, command(digest, metadata["revision"], @archive))
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

  defp command(digest, revision, bytes) do
    chunks = for <<part::binary-size(6144) <- bytes>>, do: Base.encode64(part)
    rest = rem(byte_size(bytes), 6144)

    chunks =
      if rest == 0,
        do: chunks,
        else: chunks ++ [Base.encode64(binary_part(bytes, byte_size(bytes) - rest, rest))]

    %{
      "cohort" => @cohort,
      "metadataRevision" => revision,
      "itemID" => digest,
      "inputDigest" => Digest.sha256("preview"),
      "rendererBuildDigest" => Digest.sha256("renderer"),
      "visionLabels" => [],
      "featureDigest" => Digest.sha256(bytes),
      "featureArchiveChunks" => chunks
    }
  end
end
