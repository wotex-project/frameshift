defmodule Frameshift.CLICatalogTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.CLI
  alias Frameshift.Library
  alias Frameshift.LocalAPI

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-cli-catalog-#{System.unique_integer([:positive])}")

    {:ok, library} = Library.start_link(data_dir: root, name: nil)

    on_exit(fn ->
      if Process.alive?(library), do: GenServer.stop(library)
      File.rm_rf!(root)
    end)

    %{library: library}
  end

  test "parsed metadata edits join revision checks and preserve machine labels and bytes", c do
    {:ok, master} = Library.import_master(c.library, "retained catalog fixture", attributes())
    item = master["digest"]
    :ok = Library.add_label(c.library, item, "machine", :vision, 0.8, "fixture-1")
    :ok = Library.add_label(c.library, item, "filename", :filename)
    :ok = Library.add_label(c.library, item, "old", :user)
    {:ok, before} = Library.metadata(c.library, item)

    edit =
      command([
        "metadata-edit",
        item,
        before["revision"],
        "  Cafe\u0301  ",
        "--label",
        "  Quiet  ",
        "--dismiss",
        "filename",
        "filename"
      ])

    assert {:ok, %{"updatedMetadata" => updated}} = LocalAPI.execute(c.library, edit)
    assert updated["title"] == "Café"

    assert Enum.map(updated["labels"], &{&1["label"], &1["provenance"]}) ==
             [{"Quiet", "user"}, {"machine", "vision"}]

    assert {:error, :metadata_revision_conflict} = LocalAPI.execute(c.library, edit)
    assert [%{"digest" => ^item}] = Library.search(c.library, "quiet")
    assert Library.search(c.library, "old") == []
    assert {:ok, %{"bytes" => "retained catalog fixture"}} = Library.read_object(c.library, item)

    clear = command(["metadata-edit", item, updated["revision"], "Café", "--clear-user-labels"])
    assert {:ok, %{"updatedMetadata" => cleared}} = LocalAPI.execute(c.library, clear)

    assert [%{"label" => "machine", "provenance" => "vision", "revision" => "fixture-1"}] =
             cleared["labels"]

    assert Library.search(c.library, "quiet") == []

    forged =
      command([
        "metadata-edit",
        item,
        cleared["revision"],
        "Café",
        "--clear-user-labels",
        "--dismiss",
        "metadata",
        "absent"
      ])

    assert {:error, :invalid_metadata} = LocalAPI.execute(c.library, forged)
    assert {:ok, ^cleared} = Library.metadata(c.library, item)
  end

  test "parsed storage edits reject stale observations and preserve over-budget retained bytes",
       c do
    bytes = :binary.copy(<<42>>, 2 * 1_048_576)
    {:ok, master} = Library.import_master(c.library, bytes, attributes())
    {:ok, before} = Library.storage(c.library)
    edit = command(["storage-set", before["revision"], "1048576"])
    assert {:ok, %{"updatedStorage" => updated}} = LocalAPI.execute(c.library, edit)
    assert updated["objectByteLimit"] == 1_048_576
    assert updated["totalBytes"] == byte_size(bytes)
    assert updated["overBudget"]
    assert {:error, :storage_revision_conflict} = LocalAPI.execute(c.library, edit)
    assert {:ok, %{"bytes" => ^bytes}} = Library.read_object(c.library, master["digest"])
    assert {:error, :library_storage_full} = Library.import_master(c.library, "new", attributes())
  end

  defp command(arguments) do
    {:ok, {:command, %{"command" => command}}} = CLI.parse(arguments ++ ["--id", "fixture-id"])
    command
  end

  defp attributes,
    do: %{
      title: "Fixture",
      source_kind: :import,
      width: 1,
      height: 1,
      media_type: "application/octet-stream",
      provenance: %{"fixture" => true}
    }
end
