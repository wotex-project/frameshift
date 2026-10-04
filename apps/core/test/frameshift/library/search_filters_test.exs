defmodule Frameshift.Library.SearchFiltersTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalAPI

  @thing File.read!(
           Path.expand("../../../../../protocol/fixtures/valid/thing-description.json", __DIR__)
         )

  setup do
    root = Path.join(System.tmp_dir!(), "frameshift-facets-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, library} = Library.start_link(data_dir: root, name: nil)
    {:ok, red} = Library.import_master(library, "red", attributes("Red Forest"))
    {:ok, blue} = Library.import_master(library, "blue", attributes("Blue Forest"))

    {:ok, recipe} =
      Library.register_recipe(
        library,
        :generation,
        %{"provider" => "fixture", "prompt" => "synthetic"},
        [red["digest"]]
      )

    {:ok, generated} =
      Library.add_generated_variant(
        library,
        "generated",
        attributes("Generated Forest"),
        red["digest"],
        recipe
      )

    :ok = Library.pin(library, red["digest"])

    {:ok, frame} =
      Library.register_paired_frame(
        library,
        @thing,
        "keychain:facet-frame",
        Digest.sha256("facet-frame")
      )

    %{
      library: library,
      red: red["digest"],
      blue: blue["digest"],
      generated: generated["digest"],
      frame: frame["frame_id"]
    }
  end

  test "text/source/pin facets intersect before ordering and result bounds", c do
    assert ids(Library.search(c.library, "forest", source_kind: "import")) == [c.red, c.blue]
    assert ids(Library.search(c.library, "forest", source_kind: "generated")) == [c.generated]
    assert ids(Library.search(c.library, "forest", pinned: true)) == [c.red]
    assert Library.search(c.library, "forest", source_kind: "generated", pinned: true) == []
    assert Library.search(c.library, "blue", pinned: true) == []
    assert Library.search(c.library, "", source_kind: "provider") == []
    assert Library.search(c.library, "", pinned: "true") == []
    assert Library.search(c.library, "", frame_id: %{}) == []
  end

  test "frame facets follow retained master and artifact custody, excluding removed and unreferenced art",
       c do
    :ok = Library.protect_frame_asset(c.library, c.frame, "current", c.red)

    {:ok, recipe} =
      Library.register_recipe(c.library, :composition, %{"crop" => [0, 0, 2, 1]}, [c.generated])

    {:ok, artifact} =
      Library.register_artifact(c.library, "rendered RGB", %{
        master_digest: c.generated,
        recipe_hash: recipe,
        profile_id: "fixture-rgb",
        renderer_revision: "fixture-1",
        media_type: "application/octet-stream"
      })

    :ok = Library.protect_frame_asset(c.library, c.frame, "playlist", artifact["digest"])
    assert ids(Library.search(c.library, "forest", frame_id: c.frame)) == [c.red, c.generated]

    assert ids(Library.search(c.library, "forest", frame_id: c.frame, source_kind: "generated")) ==
             [c.generated]

    assert Library.search(c.library, "blue", frame_id: c.frame) == []
    :ok = Library.remove_master(c.library, c.red)
    assert ids(Library.search(c.library, "forest", frame_id: c.frame)) == [c.generated]
    assert {:ok, []} = Library.collect_removed(c.library)
    :ok = Library.release_frame_asset(c.library, c.frame, "playlist", artifact["digest"])
    assert Library.search(c.library, "forest", frame_id: c.frame) == []
  end

  test "product reads refuse hostile facets and unknown frames without changing selection or intent",
       c do
    :ok = Library.protect_frame_asset(c.library, c.frame, "queued", c.red)
    :ok = Library.put_setting(c.library, "frame.selected", c.frame)
    :ok = Library.put_setting(c.library, "generation.instruction", "Keep this draft")

    assert {:ok, snapshot} =
             LocalAPI.filtered_snapshot(c.library, "forest", %{
               "pinnedOnly" => true,
               "sourceKind" => "import",
               "frameID" => c.frame
             })

    assert Enum.map(snapshot["items"], & &1["id"]) == [c.red]
    assert snapshot["selectedTargetID"] == c.frame
    assert snapshot["instruction"] == "Keep this draft"

    for filters <- [
          nil,
          [],
          %{"pinnedOnly" => 1},
          %{"sourceKind" => "all"},
          %{"frameID" => "unpaired"},
          %{"frameID" => String.duplicate("x", 129)},
          %{"frameID" => []},
          %{"provider" => "unknown"},
          %{"sql" => "DELETE FROM masters"}
        ] do
      assert {:error, :invalid_request} = LocalAPI.filtered_snapshot(c.library, "", filters)
    end

    assert Library.outbox_manifest(c.library, c.frame) == :empty
    assert length(Library.search(c.library, "forest")) == 3
  end

  defp ids(masters), do: Enum.map(masters, & &1["digest"])

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
