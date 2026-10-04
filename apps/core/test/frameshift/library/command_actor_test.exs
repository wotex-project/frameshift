defmodule Frameshift.Library.CommandActorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Library.Backup

  setup do
    root = "/tmp/fs-actor-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, library} = Library.start_link(data_dir: root, name: nil)
    on_exit(fn -> File.rm_rf!(root) end)
    %{library: library, root: root}
  end

  test "actor-bound success, failure and pending receipts survive restart and verified backup",
       context do
    hash = Digest.sha256("exact actor command")
    assert {:ok, :execute} = Library.claim_command_as(context.library, "success", hash, 0)
    assert :ok = Library.complete_command_as(context.library, "success", hash, 0, :ok)
    assert {:ok, :execute} = Library.claim_command_as(context.library, "failure", hash, 65_534)

    assert :ok =
             Library.complete_command_as(
               context.library,
               "failure",
               hash,
               65_534,
               {:error, :invalid_command}
             )

    assert {:ok, :execute} = Library.claim_command_as(context.library, "pending", hash, 1)
    backup = context.root <> "-backup"
    restored = context.root <> "-restored"

    on_exit(fn ->
      File.rm_rf!(backup)
      File.rm_rf!(restored)
    end)

    assert :ok = Library.create_backup(context.library, backup)
    assert :ok = Backup.verify(backup)
    assert :ok = Backup.restore(backup, restored)
    GenServer.stop(context.library)

    for root <- [context.root, restored] do
      {:ok, reopened} = Library.start_link(data_dir: root, name: nil)
      assert {:ok, {:replay, :ok}} = Library.claim_command_as(reopened, "success", hash, 0)

      assert {:ok, {:replay, {:error, "invalid_command"}}} =
               Library.claim_command_as(reopened, "failure", hash, 65_534)

      assert {:ok, :pending} = Library.claim_command_as(reopened, "pending", hash, 1)
      assert {:error, :command_id_conflict} = Library.claim_command(reopened, "success", hash)

      assert {:error, :command_id_conflict} =
               Library.claim_command_as(reopened, "failure", hash, 1)

      connection = :sys.get_state(reopened).connection

      assert Exqlite.query!(
               connection,
               "SELECT actor_uid FROM command_receipts ORDER BY command_id"
             ).rows == [[65_534], [1], [0]]

      GenServer.stop(reopened)
    end
  end

  test "actor changes cannot claim, replay or complete another authority's global ID", context do
    hash = Digest.sha256("same payload")
    library = context.library
    assert {:ok, :execute} = Library.claim_command(library, "private", hash)
    assert {:error, :command_id_conflict} = Library.claim_command_as(library, "private", hash, 0)

    assert {:error, :command_id_conflict} =
             Library.complete_command_as(library, "private", hash, 0, :ok)

    assert {:ok, :pending} = Library.claim_command(library, "private", hash)
    assert :ok = Library.complete_command(library, "private", hash, :ok)
    assert {:ok, :execute} = Library.claim_command_as(library, "group", hash, 1)

    for actor <- [nil, 0, 50, 65_534] do
      assert {:error, :command_id_conflict} =
               Library.claim_command_as(library, "group", hash, actor)

      assert {:error, :command_id_conflict} =
               Library.complete_command_as(library, "group", hash, actor, :ok)
    end

    assert {:ok, :pending} = Library.claim_command_as(library, "group", hash, 1)

    assert {:error, :command_id_conflict} =
             Library.claim_command_as(library, "group", Digest.sha256("changed"), 1)

    assert :ok = Library.complete_command_as(library, "group", hash, 1, :ok)
    assert :ok = Library.complete_command_as(library, "group", hash, 1, :ok)
    assert {:ok, {:replay, :ok}} = Library.claim_command_as(library, "group", hash, 1)
    assert {:error, :command_id_conflict} = Library.claim_command_as(library, "group", hash, 0)
    entries = Library.audit_page(library)["entries"]
    assert length(entries) == 4
    actor_entries = Enum.filter(entries, &(&1["correlationId"] == Digest.sha256("group")))

    assert Enum.all?(
             actor_entries,
             &(&1["detail"]["actorId"] == Digest.sha256("frameshift-linux-uid-v1:1"))
           )

    refute Enum.any?(entries, &Map.has_key?(&1["detail"], "actor_uid"))
  end

  test "invalid actors and aborted audit transactions leave no claim or terminal outcome",
       context do
    hash = Digest.sha256("bounded actor")
    library = context.library

    for uid <- [-1, 4_294_967_295, "1", 1.0, :root] do
      assert {:error, :invalid_command_receipt} =
               Library.claim_command_as(library, "invalid", hash, uid)

      assert {:error, :invalid_command_receipt} =
               Library.complete_command_as(library, "invalid", hash, uid, :ok)
    end

    assert Library.audit_page(library)["entries"] == []
    connection = :sys.get_state(library).connection

    Exqlite.query!(
      connection,
      "CREATE TRIGGER abort_actor_claim BEFORE INSERT ON audit_entries WHEN NEW.operation = 'command.claimed' BEGIN SELECT RAISE(ABORT, 'fixture'); END"
    )

    assert {:error, _} = Library.claim_command_as(library, "atomic", hash, 1)
    assert Exqlite.query!(connection, "SELECT command_id FROM command_receipts").rows == []
    Exqlite.query!(connection, "DROP TRIGGER abort_actor_claim")
    assert {:ok, :execute} = Library.claim_command_as(library, "atomic", hash, 1)

    Exqlite.query!(
      connection,
      "CREATE TRIGGER abort_actor_completion BEFORE INSERT ON audit_entries WHEN NEW.operation = 'command.completed' BEGIN SELECT RAISE(ABORT, 'fixture'); END"
    )

    assert {:error, _} = Library.complete_command_as(library, "atomic", hash, 1, :ok)
    assert {:ok, :pending} = Library.claim_command_as(library, "atomic", hash, 1)
    assert length(Library.audit_page(library)["entries"]) == 1
  end
end
