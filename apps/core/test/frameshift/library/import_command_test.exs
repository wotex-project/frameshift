defmodule Frameshift.Library.ImportCommandTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Library.Backup
  alias Frameshift.MasterPackage

  @actor 501
  @hash Digest.sha256("canonical original intent fixture")

  setup do
    directory =
      Path.join(System.tmp_dir!(), "import-receipt-#{System.unique_integer([:positive])}")

    {:ok, library} = Library.start_link(name: nil, data_dir: directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{library: library, directory: directory}
  end

  test "master, exact receipt and correlated import/completion audits commit once", %{
    library: library
  } do
    bytes = package("original")
    digest = Digest.sha256(bytes)
    assert {:ok, receipt} = run_import(library, bytes)
    assert receipt == %{"status" => "succeeded", "errorCode" => nil, "importedItemID" => digest}
    assert {:ok, ^receipt} = Library.command_receipt_as(library, "import-1", @actor, @hash)
    assert {:ok, %{"bytes" => ^bytes}} = Library.read_object(library, digest)
    assert {:ok, master} = Library.get_master(library, digest)
    assert master["provenance_json"] == attributes().provenance

    assert {:ok, ^receipt} = run_import(library, package("original", <<24, 34, 56, 255>>))
    assert Library.command_receipt_as(library, "import-1", @actor) == {:ok, receipt}

    assert audit_operations(library) == [
             "command.completed",
             "master.imported",
             "command.claimed"
           ]

    assert %{"entries" => entries} = Library.audit_page(library)

    for entry <- entries do
      assert entry["correlationId"] == Digest.sha256("import-1")
      assert entry["detail"]["actorId"] == Digest.sha256("frameshift-linux-uid-v1:501")
    end
  end

  test "actor and payload conflicts cannot place alternate bytes or expose another actor's result",
       %{library: library, directory: directory} do
    assert {:ok, _} = run_import(library, package("first"))
    alternate = package("alternate")

    for {actor, hash} <- [{502, @hash}, {@actor, Digest.sha256("changed payload")}] do
      assert {:error, :command_id_conflict} =
               Library.import_master_command_as(
                 library,
                 alternate,
                 attributes(),
                 "import-1",
                 hash,
                 actor
               )

      assert {:error, :command_id_conflict} =
               Library.command_receipt_as(library, "import-1", actor, hash)
    end

    assert {:error, :command_id_conflict} = Library.command_receipt_as(library, "import-1", 502)
    refute File.exists?(ContentStore.object_path(directory, Digest.sha256(alternate)))
    assert length(audit_operations(library)) == 3
  end

  test "a pending claim never imports again, including after a fresh writer restart", %{
    library: library,
    directory: directory
  } do
    assert {:ok, :execute} = Library.claim_command_as(library, "import-1", @hash, @actor)
    assert {:error, :command_outcome_unknown} = run_import(library, package("pending source"))

    assert {:ok, %{"status" => "pending", "importedItemID" => nil}} =
             Library.command_receipt_as(library, "import-1", @actor)

    assert Library.search(library, "") == []
    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(name: nil, data_dir: directory)
    assert {:error, :command_outcome_unknown} = run_import(restarted, package("pending source"))
    assert audit_operations(restarted) == ["command.claimed"]
    GenServer.stop(restarted)
  end

  test "terminal replay preserves its original result across restart and changed codec output", %{
    library: library,
    directory: directory
  } do
    first = package("source-v1")
    changed = package("source-v1", <<24, 34, 56, 255>>)
    assert {:ok, receipt} = run_import(library, first)
    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(name: nil, data_dir: directory)
    assert {:ok, ^receipt} = run_import(restarted, changed)
    assert {:ok, ^receipt} = Library.command_receipt_as(restarted, "import-1", @actor)
    refute File.exists?(ContentStore.object_path(directory, Digest.sha256(changed)))
    assert length(audit_operations(restarted)) == 3
    GenServer.stop(restarted)
  end

  test "terminal replay neither pins nor restores subsequently removed artwork", %{
    library: library,
    directory: directory
  } do
    bytes = package("removable")
    assert {:ok, %{"importedItemID" => digest} = receipt} = run_import(library, bytes)
    :ok = Library.remove_master(library, digest)
    assert {:ok, [^digest]} = Library.collect_removed(library)
    refute File.exists?(ContentStore.object_path(directory, digest))
    assert {:ok, ^receipt} = run_import(library, bytes)
    refute File.exists?(ContentStore.object_path(directory, digest))
    assert {:ok, %{"removed_at_ms" => removed}} = Library.get_master(library, digest)
    assert is_integer(removed)
    assert File.exists?(ContentStore.trash_path(directory, digest))
  end

  test "concurrent exact finishes commit one import and report the same result", %{
    library: library
  } do
    bytes = package("concurrent")

    results =
      Task.async_stream(1..16, fn _ -> run_import(library, bytes) end, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [
             {:ok,
              %{
                "status" => "succeeded",
                "errorCode" => nil,
                "importedItemID" => Digest.sha256(bytes)
              }}
           ]

    assert length(audit_operations(library)) == 3
  end

  test "rollback after result update preserves the pending claim and orphan, without registered success",
       %{library: library, directory: directory} do
    database = :sys.get_state(library).connection

    Exqlite.query!(database, """
    CREATE TRIGGER reject_import_completion BEFORE INSERT ON audit_entries
    WHEN NEW.operation = 'command.completed'
    BEGIN SELECT RAISE(ABORT, 'injected completion failure'); END
    """)

    bytes = package("rollback")
    digest = Digest.sha256(bytes)
    assert {:error, :command_outcome_unknown} = run_import(library, bytes)

    assert {:ok, %{"status" => "pending", "importedItemID" => nil}} =
             Library.command_receipt_as(library, "import-1", @actor)

    assert :not_found = Library.get_master(library, digest)
    assert audit_operations(library) == ["command.claimed"]
    assert File.read!(ContentStore.object_path(directory, digest)) == bytes
    Exqlite.query!(database, "DROP TRIGGER reject_import_completion")
    assert {:error, :command_outcome_unknown} = run_import(library, bytes)
    assert :not_found = Library.get_master(library, digest)

    assert {:ok, %{"importedItemID" => ^digest}} =
             Library.import_master_command_as(
               library,
               bytes,
               attributes(),
               "explicit-new-id",
               @hash,
               @actor
             )

    assert {:ok, %{"status" => "pending"}} =
             Library.command_receipt_as(library, "import-1", @actor)
  end

  test "lost caller reply recovers exact success after restart without reimporting", %{
    library: library,
    directory: directory
  } do
    parent = self()
    bytes = package("lost-reply")

    spawn(fn ->
      :gen_server.send_request(
        library,
        {:import_master_command, bytes, attributes(), "import-1", @hash, @actor}
      )

      send(parent, :request_sent)
      Process.exit(self(), :kill)
    end)

    assert_receive :request_sent
    assert {:ok, receipt} = Library.command_receipt_as(library, "import-1", @actor)
    assert receipt["status"] == "succeeded"
    assert receipt["importedItemID"] == Digest.sha256(bytes)
    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(name: nil, data_dir: directory)
    assert {:ok, ^receipt} = Library.command_receipt_as(restarted, "import-1", @actor)
    assert length(audit_operations(restarted)) == 3
    GenServer.stop(restarted)
  end

  test "canonical package/metadata refusal precedes command claim", %{library: library} do
    bytes = package("valid")

    for {source, attrs} <- [
          {"not a package", attributes()},
          {:invalid_iodata, attributes()},
          {bytes, nil},
          {bytes, %{attributes() | width: 2}},
          {bytes, %{attributes() | orientation: 6}},
          {bytes, %{attributes() | color_profile: "DisplayP3"}},
          {bytes, %{attributes() | media_type: "image/png"}},
          {bytes, %{attributes() | source_kind: :generated}},
          {bytes, %{attributes() | provenance: "invalid"}}
        ] do
      assert {:error, :invalid_import_package} = run_import(library, source, attrs)
      assert :not_found = Library.command_receipt_as(library, "import-1", @actor)
    end

    assert audit_operations(library) == []
  end

  test "ordinary and null-actor receipts retain their boundary without becoming imports", %{
    library: library
  } do
    assert {:ok, :execute} = Library.claim_command(library, "import-1", @hash)
    assert :ok = Library.complete_command(library, "import-1", @hash, :ok)
    assert {:error, :command_id_conflict} = run_import(library, package("source"))
    assert {:error, :command_id_conflict} = Library.command_receipt_as(library, "import-1", 0)

    assert {:ok, %{"status" => "succeeded", "importedItemID" => nil}} =
             Library.command_receipt_as(library, "import-1", nil)

    assert {:ok, :execute} = Library.claim_command_as(library, "ordinary", @hash, @actor)
    assert :ok = Library.complete_command_as(library, "ordinary", @hash, @actor, :ok)

    assert {:error, :command_id_conflict} =
             Library.import_master_command_as(
               library,
               package("source"),
               attributes(),
               "ordinary",
               @hash,
               @actor
             )

    assert Library.search(library, "") == []
  end

  test "terminal storage refusal replays without retrying placement", %{
    library: library,
    directory: directory
  } do
    assert {:ok, %{"revision" => revision}} = Library.storage(library)
    assert {:ok, _} = Library.update_storage(library, revision, 1_048_576)
    bytes = package(:binary.copy("x", 1_048_576))
    assert {:error, :library_storage_full} = run_import(library, bytes)

    assert {:ok,
            %{
              "status" => "failed",
              "errorCode" => "library_storage_full",
              "importedItemID" => nil
            }} = Library.command_receipt_as(library, "import-1", @actor)

    assert {:error, "library_storage_full"} = run_import(library, bytes)
    refute File.exists?(ContentStore.object_path(directory, Digest.sha256(bytes)))

    assert audit_operations(library) |> Enum.filter(&String.starts_with?(&1, "command.")) == [
             "command.completed",
             "command.claimed"
           ]
  end

  test "receipt validation refuses malformed identities and schema forbids false result states",
       %{library: library} do
    assert :not_found = Library.command_receipt_as(library, "missing", @actor)
    assert {:error, :invalid_command_receipt} = Library.command_receipt_as(library, "", @actor)
    assert {:error, :invalid_command_receipt} = Library.command_receipt_as(library, "id", -1)

    assert {:error, :invalid_command_hash} =
             Library.command_receipt_as(library, "id", @actor, "wrong")

    for {hash, actor} <- [{nil, @actor}, {@hash, nil}, {@hash, -1}, {@hash, 4_294_967_295}] do
      assert {:error, :invalid_command_receipt} =
               Library.import_master_command_as(
                 library,
                 package("source"),
                 attributes(),
                 "import-1",
                 hash,
                 actor
               )
    end

    assert {:ok, :execute} = Library.claim_command_as(library, "pending", @hash, @actor)
    database = :sys.get_state(library).connection

    assert_raise Exqlite.Error, fn ->
      Exqlite.query!(
        database,
        "UPDATE command_receipts SET imported_master_digest = ? WHERE command_id = 'pending'",
        [Digest.sha256("uncommitted")]
      )
    end

    assert :ok = Library.complete_command_as(library, "pending", @hash, @actor, :ok)

    for invalid <- ["sha256:wrong", "sha256:" <> String.duplicate("A", 64)] do
      assert_raise Exqlite.Error, fn ->
        Exqlite.query!(
          database,
          "UPDATE command_receipts SET imported_master_digest = ? WHERE command_id = 'pending'",
          [invalid]
        )
      end
    end
  end

  test "an owner fault report redacts raw source, path and failure context", %{
    library: library,
    directory: directory
  } do
    Process.flag(:trap_exit, true)
    secret = "library-private-source-fixture"

    logs =
      capture_log(fn ->
        GenServer.stop(library, {:fixture_failure, secret})
      end)

    refute logs =~ secret
    refute logs =~ "fixture_failure"
    refute logs =~ directory
    assert logs =~ "library_owner_failure"
  end

  test "verified backup and offline restore retain exact terminal and pending receipts", %{
    library: library,
    directory: directory
  } do
    assert {:ok, receipt} = run_import(library, package("backup source"))
    assert {:ok, :execute} = Library.claim_command_as(library, "pending-backup", @hash, @actor)
    backup = directory <> "-backup"
    restored = directory <> "-restored"

    on_exit(fn ->
      File.rm_rf!(backup)
      File.rm_rf!(restored)
    end)

    assert :ok = Library.create_backup(library, backup)
    assert :ok = Backup.verify(backup)
    assert :ok = Backup.restore(backup, restored)
    {:ok, recovered} = Library.start_link(name: nil, data_dir: restored)
    assert {:ok, ^receipt} = Library.command_receipt_as(recovered, "import-1", @actor, @hash)

    assert {:ok, %{"status" => "pending", "importedItemID" => nil}} =
             Library.command_receipt_as(recovered, "pending-backup", @actor)

    assert {:ok, ^receipt} = run_import(recovered, package("backup source", <<24, 34, 56, 255>>))
    GenServer.stop(recovered)
  end

  defp run_import(library, bytes, attrs \\ attributes()) do
    Library.import_master_command_as(library, bytes, attrs, "import-1", @hash, @actor)
  end

  defp package(original, rgba \\ <<12, 34, 56, 255>>) do
    {:ok, bytes} = MasterPackage.encode(original, rgba, 1, 1)
    IO.iodata_to_binary(bytes)
  end

  defp attributes do
    %{
      title: "Original import",
      source_kind: :import,
      width: 1,
      height: 1,
      media_type: MasterPackage.media_type(),
      orientation: 1,
      color_profile: "sRGB",
      provenance: %{"kind" => "local-import", "codecDigest" => Digest.sha256("producer fixture")}
    }
  end

  defp audit_operations(library) do
    %{"entries" => entries} = Library.audit_page(library)
    Enum.map(entries, & &1["operation"])
  end
end
