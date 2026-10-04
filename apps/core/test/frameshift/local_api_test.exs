defmodule Frameshift.LocalAPITest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalAPI
  alias Frameshift.MasterPackage

  @png <<137, "PNG\r\n", 26, 10, 0, 0, 0, 13, "IHDR", 0, 0, 0, 2, 0, 0, 0, 1, 8, 6, 0, 0, 0>>
  @rgba <<255, 0, 0, 255, 0, 255, 0, 128>>
  @frame_fixture Path.expand(
                   "../../../../protocol/fixtures/valid/thing-description.json",
                   __DIR__
                 )

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "frameshift-local-api-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    data_dir = Path.join(root, "library")
    import_path = Path.join(root, "quiet-study.png")
    canonical_path = Path.join(root, "quiet-study.rgba")
    File.mkdir_p!(root)
    File.write!(import_path, @png, [:binary])
    File.write!(canonical_path, @rgba, [:binary])
    {:ok, library} = Library.start_link(data_dir: data_dir, name: nil)

    on_exit(fn ->
      stop_if_alive(library)
      File.rm_rf!(root)
    end)

    %{
      canonical_path: canonical_path,
      data_dir: data_dir,
      import_path: import_path,
      library: library
    }
  end

  test "commands mutate durable core state rather than a shell-owned copy", context do
    assert %{
             "targets" => [],
             "selectedTargetID" => nil,
             "items" => [],
             "generationAvailability" => "notConfigured"
           } = LocalAPI.snapshot(context.library)

    assert {:ok, snapshot} =
             LocalAPI.execute(context.library, %{
               "kind" => "updateInstruction",
               "instruction" => "A quiet geometric still"
             })

    assert snapshot["instruction"] == "A quiet geometric still"

    assert {:ok, imported} =
             LocalAPI.execute(
               context.library,
               import_command(context.import_path, context.canonical_path)
             )

    assert [%{"title" => "quiet-study", "isPinned" => false} = item] = imported["items"]

    assert {:ok, %{"bytes" => package}} = Library.read_object(context.library, item["digest"])

    assert {:ok, %{rgba: @rgba, original: @png, width: 2, height: 1}} =
             MasterPackage.decode(package)

    assert {:ok, pinned} =
             LocalAPI.execute(context.library, %{
               "kind" => "setPinned",
               "itemID" => item["id"],
               "isPinned" => true
             })

    assert [%{"isPinned" => true}] = pinned["items"]

    GenServer.stop(context.library)
    {:ok, restarted} = Library.start_link(data_dir: context.data_dir, name: nil)

    assert %{"instruction" => "A quiet geometric still", "items" => [persisted]} =
             LocalAPI.snapshot(restarted)

    assert persisted["digest"] == item["digest"]
    assert persisted["isPinned"]

    GenServer.stop(restarted)
  end

  test "import validates Apple-decoded metadata against the actual file type", context do
    assert {:error, :media_type_mismatch} =
             context.import_path
             |> import_command(context.canonical_path)
             |> Map.put("importMediaType", "image/jpeg")
             |> then(&LocalAPI.execute(context.library, &1))

    assert {:error, :invalid_dimensions} =
             context.import_path
             |> import_command(context.canonical_path)
             |> Map.put("importWidth", 0)
             |> then(&LocalAPI.execute(context.library, &1))

    assert {:error, :invalid_dimensions} =
             context.import_path
             |> import_command(context.canonical_path)
             |> Map.merge(%{"importWidth" => 4_096, "importHeight" => 4_096})
             |> then(&LocalAPI.execute(context.library, &1))

    assert {:error, :invalid_command} =
             context.import_path
             |> import_command(context.canonical_path)
             |> Map.put("credential", "must-not-cross-this-boundary")
             |> then(&LocalAPI.execute(context.library, &1))

    assert {:error, :canonical_digest_mismatch} =
             context.import_path
             |> import_command(context.canonical_path)
             |> Map.put("importCanonicalDigest", "sha256:" <> String.duplicate("0", 64))
             |> then(&LocalAPI.execute(context.library, &1))
  end

  test "pin-set preview is independent of search and refuses truncation beyond the local limit",
       context do
    for index <- 1..65 do
      {:ok, master} =
        Library.import_master(context.library, "pinned-fixture-#{index}", %{
          title: "Pinned #{index}",
          source_kind: :import,
          width: 1,
          height: 1,
          media_type: "application/octet-stream",
          provenance: %{"fixture" => true}
        })

      :ok = Library.pin(context.library, master["digest"])
    end

    snapshot = LocalAPI.snapshot(context.library, nil, "no-matching-title")
    assert snapshot["items"] == []
    assert length(snapshot["pinnedItems"]) == 64
    assert snapshot["pinnedSetTooLarge"]
  end

  test "remove is recoverable library state and unavailable target commands fail explicitly",
       context do
    assert {:ok, imported} =
             LocalAPI.execute(
               context.library,
               import_command(context.import_path, context.canonical_path)
             )

    [item] = imported["items"]

    assert {:ok, %{"items" => []}} =
             LocalAPI.execute(context.library, %{"kind" => "remove", "itemID" => item["id"]})

    assert {:ok, _} = Library.get_master(context.library, item["digest"])
    assert {:error, :invalid_command} = LocalAPI.execute(context.library, %{"kind" => "queue"})

    missing = "sha256:" <> String.duplicate("0", 64)

    assert {:error, :item_not_found} =
             LocalAPI.execute(context.library, %{
               "kind" => "setPinned",
               "itemID" => missing,
               "isPinned" => false
             })
  end

  test "snapshot and selection use durable paired frame records", context do
    assert {:ok, _} =
             Library.register_paired_frame(
               context.library,
               File.read!(@frame_fixture),
               "keychain:local-api-frame",
               "sha256:" <> String.duplicate("c", 64)
             )

    assert %{
             "targets" => [
               %{
                 "id" => "sim-photo-00000001",
                 "medium" => "photo",
                 "profileID" => "urn:frameshift:profile:sim-rgb24-v1"
               }
             ],
             "selectedTargetID" => "sim-photo-00000001"
           } = LocalAPI.snapshot(context.library)

    assert {:ok, %{"selectedTargetID" => "sim-photo-00000001"}} =
             LocalAPI.execute(context.library, %{
               "kind" => "selectTarget",
               "targetID" => "sim-photo-00000001"
             })

    assert {:error, :target_not_found} =
             LocalAPI.execute(context.library, %{
               "kind" => "selectTarget",
               "targetID" => "missing-frame"
             })
  end

  test "a push-only frame is not misreported as queued to a pull outbox", context do
    push_only_td =
      @frame_fixture
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["frameshift:capabilities", "transferModes"], ["push"])
      |> Jason.encode!()

    assert {:ok, frame} =
             Library.register_paired_frame(
               context.library,
               push_only_td,
               "keychain:push-only-frame",
               "sha256:" <> String.duplicate("c", 64)
             )

    assert {:ok, imported} =
             LocalAPI.execute(
               context.library,
               import_command(context.import_path, context.canonical_path)
             )

    [item] = imported["items"]

    assert {:error, :credential_broker_unavailable} =
             LocalAPI.execute(context.library, %{
               "kind" => "queue",
               "targetID" => frame["frame_id"],
               "itemID" => item["id"]
             })

    assert :empty = Library.outbox_manifest(context.library, frame["frame_id"])
  end

  defp import_command(path, canonical_path) do
    %{
      "kind" => "importFile",
      "importPath" => path,
      "importCanonicalPath" => canonical_path,
      "importCanonicalDigest" => Digest.sha256(@rgba),
      "importWidth" => 2,
      "importHeight" => 1,
      "importMediaType" => "image/png",
      "importOrientation" => 1,
      "importColorProfile" => "sRGB"
    }
  end

  defp stop_if_alive(process) do
    if Process.alive?(process), do: GenServer.stop(process)
  catch
    :exit, _ -> :ok
  end
end
