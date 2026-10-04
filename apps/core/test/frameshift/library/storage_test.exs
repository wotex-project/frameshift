defmodule Frameshift.Library.StorageTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalAPI

  @mib 1024 * 1024

  setup do
    root = Path.join(System.tmp_dir!(), "frameshift-budget-#{System.unique_integer([:positive])}")
    {:ok, library} = Library.start_link(data_dir: root, name: nil)

    on_exit(fn ->
      stop(library)
      File.rm_rf!(root)
    end)

    %{root: root, library: library}
  end

  test "exact boundary accepts unique bytes, duplicate reuse and restart; overflow places nothing",
       c do
    {:ok, initial} = Library.storage(c.library)
    assert initial["objectByteLimit"] == 20 * 1024 * @mib
    assert {:ok, _} = Library.update_storage(c.library, initial["revision"], @mib)
    bytes = :binary.copy(<<1>>, @mib)
    assert {:ok, master} = Library.import_master(c.library, bytes, attributes())
    assert {:ok, _} = Library.import_master(c.library, bytes, attributes())
    {:ok, full} = Library.storage(c.library)
    assert full["totalBytes"] == @mib
    assert full["objectCount"] == 1
    assert full["remainingBytes"] == 0
    refute full["overBudget"]
    audit = Library.audit_page(c.library)
    assert {:error, :library_storage_full} = Library.import_master(c.library, "new", attributes())
    assert Library.audit_page(c.library) == audit
    refute File.exists?(ContentStore.object_path(c.root, Digest.sha256("new")))
    assert {:ok, ^full} = Library.storage(c.library)
    GenServer.stop(c.library)
    {:ok, restarted} = Library.start_link(data_dir: c.root, name: nil)
    assert {:ok, ^full} = Library.storage(restarted)
    assert {:ok, %{"bytes" => ^bytes}} = Library.read_object(restarted, master["digest"])
    GenServer.stop(restarted)
  end

  test "lowering below usage preserves trash, restore and reads without freeing allowance", c do
    bytes = :binary.copy(<<2>>, 2 * @mib)
    {:ok, master} = Library.import_master(c.library, bytes, attributes())
    {:ok, before} = Library.storage(c.library)
    {:ok, lowered} = Library.update_storage(c.library, before["revision"], @mib)
    assert lowered["overBudget"]
    :ok = Library.remove_master(c.library, master["digest"])
    assert {:ok, [_]} = Library.collect_removed(c.library)
    {:ok, trash} = Library.storage(c.library)
    assert trash["trashBytes"] == 2 * @mib
    assert trash["totalBytes"] == lowered["totalBytes"]
    assert trash["remainingBytes"] == 0
    assert :ok = Library.restore_master(c.library, master["digest"])
    assert {:ok, %{"bytes" => ^bytes}} = Library.read_object(c.library, master["digest"])
    assert {:ok, ^lowered} = Library.storage(c.library)
    assert :ok = Library.pin(c.library, master["digest"])

    assert {:error, :library_storage_full} =
             Library.import_master(c.library, "other", attributes())
  end

  test "generated and artifact objects share admission; serialized imports cannot oversubscribe",
       c do
    {:ok, initial} = Library.storage(c.library)
    {:ok, _} = Library.update_storage(c.library, initial["revision"], @mib)

    results =
      [3, 4]
      |> Task.async_stream(fn value ->
        Library.import_master(c.library, :binary.copy(<<value>>, @mib), attributes())
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :library_storage_full} in results
    {:ok, master} = Enum.find(results, &match?({:ok, _}, &1))
    {:ok, generation} = Library.register_recipe(c.library, :generation, %{"fixture" => true}, [])

    assert {:error, :library_storage_full} =
             Library.add_generated_master(
               c.library,
               "generation",
               attributes(:generated),
               generation
             )

    {:ok, recipe} = Library.register_recipe(c.library, :composition, %{}, [master["digest"]])

    assert {:error, :library_storage_full} =
             Library.register_artifact(c.library, "render", %{
               master_digest: master["digest"],
               recipe_hash: recipe,
               profile_id: "rgb24-v1",
               renderer_revision: "fixture-v1",
               media_type: "application/octet-stream"
             })

    {:ok, usage} = Library.storage(c.library)
    assert usage["objectCount"] == 1
    assert usage["totalBytes"] == @mib
    refute File.exists?(ContentStore.object_path(c.root, Digest.sha256("render")))
  end

  test "stale configuration, invalid bounds and unknown command keys preserve budget", c do
    {:ok, initial} = Library.storage(c.library)

    command = %{
      "kind" => "updateStorage",
      "storageRevision" => initial["revision"],
      "objectByteLimit" => @mib
    }

    assert {:ok, %{"updatedStorage" => committed}} = LocalAPI.execute(c.library, command)

    assert {:error, :storage_revision_conflict} =
             LocalAPI.execute(c.library, %{command | "objectByteLimit" => 2 * @mib})

    assert {:error, :invalid_command} =
             LocalAPI.execute(c.library, Map.put(command, "path", c.root))

    for invalid <- [0, @mib - 1, 1024 * 1024 * @mib + 1, 1.0, "100", nil] do
      assert {:error, :invalid_storage_setting} =
               Library.update_storage(c.library, committed["revision"], invalid)
    end

    assert {:ok, ^committed} = Library.storage(c.library)
    assert %{"entries" => entries} = Library.audit_page(c.library)

    assert [%{"detail" => %{}}] =
             Enum.filter(entries, &(&1["operation"] == "storage_budget_changed"))
  end

  test "audit failure rolls back settings; malformed persisted configuration fails closed", c do
    {:ok, initial} = Library.storage(c.library)
    {:ok, database} = Exqlite.start_link(database: Path.join(c.root, "metadata.sqlite"))
    on_exit(fn -> stop(database) end)

    Exqlite.query!(
      database,
      "CREATE TRIGGER reject_budget_audit BEFORE INSERT ON audit_entries WHEN NEW.operation = 'storage_budget_changed' BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END"
    )

    assert {:error, {:database, _}} = Library.update_storage(c.library, initial["revision"], @mib)
    assert {:ok, ^initial} = Library.storage(c.library)
    :ok = Library.put_setting(c.library, "storage.objectByteLimit", "broken")
    assert {:error, :storage_configuration_invalid} = Library.storage(c.library)

    assert {:error, :storage_configuration_invalid} =
             Library.import_master(c.library, "refused", attributes())

    assert {:error, :storage_configuration_invalid} =
             Library.update_storage(c.library, initial["revision"], @mib)

    assert {:ok, "broken"} = Library.get_setting(c.library, "storage.objectByteLimit")
  end

  defp attributes(kind \\ :import),
    do: %{
      title: "Budget fixture",
      source_kind: kind,
      width: 1,
      height: 1,
      media_type: "application/octet-stream",
      provenance: %{"fixture" => true}
    }

  defp stop(process) do
    if Process.alive?(process), do: GenServer.stop(process)
  catch
    :exit, _ -> :ok
  end
end
