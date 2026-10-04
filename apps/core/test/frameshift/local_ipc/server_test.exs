defmodule Frameshift.LocalIPC.ServerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.LocalIPC.Server

  @token String.duplicate("a", 64)
  @pairing_device_id "sim-photo-00000001"
  @pairing_thing File.read!(
                   Path.expand(
                     "../../../../../protocol/fixtures/valid/thing-description.json",
                     __DIR__
                   )
                 )
                 |> String.replace("https://frame.invalid/", "https://frame.local/")

  defmodule PairingResolver do
    @moduledoc false

    @spec resolve(term(), map()) :: {:ok, map()}
    def resolve(_, _) do
      {:ok, %{certificate: <<1, 2, 3>>, private_key: {:rsa, :test_key}}}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "frameshift-local-ipc-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    data_dir = Path.join(root, "library")
    socket_path = Path.join(root, "run/core.sock")
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, library} = Library.start_link(data_dir: data_dir, name: nil)

    {:ok, server} =
      Server.start_link(
        path: socket_path,
        token: @token,
        library: library,
        task_supervisor: task_supervisor,
        name: nil
      )

    on_exit(fn ->
      for process <- [server, library, task_supervisor], Process.alive?(process) do
        stop_process(process)
      end

      File.rm_rf!(root)
    end)

    %{library: library, server: server, socket_path: socket_path}
  end

  test "serves one correlated bounded snapshot over a private Unix socket", context do
    request_id = "88e55c07-d08a-4c6e-9a9e-483d3ae68cd5"

    response =
      request(context.socket_path, %{
        "version" => 1,
        "requestId" => request_id,
        "operation" => "snapshot"
      })

    assert %{
             "version" => 1,
             "requestId" => ^request_id,
             "ok" => true,
             "snapshot" => %{"items" => [], "targets" => []}
           } = response

    assert %File.Stat{type: :other, mode: mode} = File.lstat!(context.socket_path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(context.socket_path)).mode, 0o777) == 0o700
  end

  test "storage read and revision-bound command retain authentication and replay custody", c do
    read = %{"version" => 1, "requestId" => "storage-read", "operation" => "libraryStorage"}
    assert %{"ok" => true, "storage" => before} = request(c.socket_path, read)
    refute Map.has_key?(before, "path")

    command = %{
      "id" => "storage-budget-command",
      "kind" => "updateStorage",
      "storageRevision" => before["revision"],
      "objectByteLimit" => 1024 * 1024
    }

    mutation = %{
      "version" => 1,
      "requestId" => "storage-save",
      "operation" => "command",
      "command" => command
    }

    assert %{"ok" => true, "snapshot" => %{"updatedStorage" => committed}} =
             request(c.socket_path, mutation)

    assert committed["objectByteLimit"] == 1024 * 1024
    assert %{"ok" => true} = request(c.socket_path, mutation)
    assert %{"ok" => true, "storage" => ^committed} = request(c.socket_path, read)

    assert %{"ok" => false, "error" => %{"code" => "authentication_required"}} =
             request(c.socket_path, Map.put(read, "auth", String.duplicate("b", 64)))

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request(c.socket_path, Map.put(read, "itemID", "unexpected"))

    assert %{"entries" => entries} = Library.audit_page(c.library)
    assert Enum.count(entries, &(&1["operation"] == "storage_budget_changed")) == 1
  end

  test "a bounded snapshot query filters cards without mutating library state", context do
    attributes = %{
      title: "Copper Forest",
      source_kind: :import,
      width: 2,
      height: 1,
      media_type: "image/png",
      provenance: %{"kind" => "local-import"}
    }

    {:ok, master} = Library.import_master(context.library, "search bytes", attributes)

    filtered =
      request(context.socket_path, %{
        "version" => 1,
        "requestId" => "search-request",
        "operation" => "snapshot",
        "query" => "copp"
      })

    assert %{"ok" => true, "snapshot" => %{"items" => [%{"digest" => digest}]}} = filtered
    assert digest == master["digest"]

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request(context.socket_path, %{
               "version" => 1,
               "requestId" => "long-search-request",
               "operation" => "snapshot",
               "query" => String.duplicate("x", 257)
             })

    assert %{"ok" => true, "snapshot" => %{"items" => [_]}} =
             request(context.socket_path, %{
               "version" => 1,
               "requestId" => "empty-search-request",
               "operation" => "snapshot"
             })
  end

  test "snapshot facets refuse hostile input and intersect source/pins over authenticated IPC",
       context do
    {:ok, master} =
      Library.import_master(context.library, "facet bytes", %{
        title: "Quiet Forest",
        source_kind: :import,
        width: 2,
        height: 1,
        media_type: "image/png",
        provenance: %{}
      })

    :ok = Library.pin(context.library, master["digest"])
    digest = master["digest"]

    base = %{
      "version" => 1,
      "requestId" => "facet-read",
      "operation" => "snapshot",
      "query" => "quiet"
    }

    assert %{"ok" => true, "snapshot" => %{"items" => [%{"id" => ^digest}]}} =
             request(
               context.socket_path,
               Map.put(base, "filters", %{"pinnedOnly" => true, "sourceKind" => "import"})
             )

    assert %{"ok" => true, "snapshot" => %{"items" => []}} =
             request(
               context.socket_path,
               Map.put(base, "filters", %{"sourceKind" => "generated"})
             )

    for filters <- [
          nil,
          %{"pinnedOnly" => "true"},
          %{"sourceKind" => "cloud"},
          %{"frameID" => "not-paired"},
          %{"frameID" => %{}},
          %{"unknown" => true}
        ] do
      assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
               request(context.socket_path, Map.put(base, "filters", filters))
    end

    assert [%{"pinned" => true, "digest" => ^digest}] = Library.search(context.library, "quiet")
  end

  test "executes a command and returns the authoritative snapshot", context do
    response =
      request(context.socket_path, %{
        "version" => 1,
        "requestId" => "request-2",
        "operation" => "command",
        "command" => %{
          "id" => "command-2",
          "kind" => "updateInstruction",
          "instruction" => "Stored by the core"
        }
      })

    assert response["ok"]
    assert response["snapshot"]["instruction"] == "Stored by the core"

    refreshed =
      request(context.socket_path, %{
        "version" => 1,
        "requestId" => "request-3",
        "operation" => "snapshot"
      })

    assert refreshed["snapshot"]["instruction"] == "Stored by the core"
  end

  test "metadata and paginated recovery authenticate, refuse forged reads and replay edits once",
       context do
    {:ok, master} =
      Library.import_master(context.library, "metadata bytes", %{
        title: "Original",
        source_kind: :import,
        width: 2,
        height: 1,
        media_type: "image/png",
        provenance: %{"kind" => "local-import"}
      })

    digest = master["digest"]

    read = %{
      "version" => 1,
      "requestId" => "metadata-read",
      "operation" => "libraryMetadata",
      "itemID" => digest
    }

    assert %{"ok" => false, "error" => %{"code" => "authentication_required"}} =
             request(context.socket_path, Map.put(read, "auth", String.duplicate("b", 64)))

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request(context.socket_path, Map.put(read, "path", "arbitrary"))

    assert %{"ok" => true, "metadata" => metadata} = request(context.socket_path, read)

    command = %{
      "id" => "metadata-edit",
      "kind" => "updateMetadata",
      "itemID" => digest,
      "metadataRevision" => metadata["revision"],
      "title" => "Saved",
      "userLabels" => ["quiet"],
      "dismissedLabels" => []
    }

    envelope = %{
      "version" => 1,
      "requestId" => "metadata-command",
      "operation" => "command",
      "command" => command
    }

    assert %{"ok" => true, "snapshot" => %{"updatedMetadata" => committed}} =
             request(context.socket_path, envelope)

    assert committed["title"] == "Saved"

    assert %{"ok" => true} =
             request(context.socket_path, Map.put(envelope, "requestId", "metadata-replay"))

    assert {:ok, ^committed} = Library.metadata(context.library, digest)
    assert %{"entries" => entries} = Library.audit_page(context.library)
    assert Enum.count(entries, &(&1["operation"] == "master.metadata-updated")) == 1
    :ok = Library.remove_master(context.library, digest)
    recovery = %{"version" => 1, "requestId" => "recovery-read", "operation" => "libraryRecovery"}

    assert %{"ok" => true, "recovery" => %{"items" => [%{"id" => ^digest}], "nextCursor" => nil}} =
             request(context.socket_path, recovery)

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request(context.socket_path, Map.put(recovery, "afterID", "path"))

    restore =
      Map.put(envelope, "command", %{"id" => "restore", "kind" => "restore", "itemID" => digest})

    assert %{"ok" => true, "snapshot" => %{"items" => [%{"id" => ^digest}]}} =
             request(context.socket_path, restore)
  end

  test "preview reads authenticate and reject paths, forged capabilities and incomplete target identity",
       context do
    base = %{
      "version" => 1,
      "requestId" => "preview-request",
      "operation" => "preview",
      "itemID" => Digest.sha256("missing")
    }

    assert %{"ok" => false, "error" => %{"code" => "item_not_found"}} =
             request(context.socket_path, base)

    assert %{"ok" => false, "error" => %{"code" => "authentication_required"}} =
             request(context.socket_path, Map.put(base, "auth", String.duplicate("b", 64)))

    for fields <- [
          %{"path" => "/tmp/caller-image"},
          %{"capabilities" => %{}},
          %{"targetID" => "frame"},
          %{"profileID" => "profile"}
        ] do
      assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
               request(context.socket_path, Map.merge(base, fields))
    end

    assert Process.alive?(context.server)
  end

  test "replays a completed command without executing it again and rejects conflicting reuse",
       context do
    command = %{
      "id" => "stable-command-id",
      "kind" => "updateInstruction",
      "instruction" => "First value"
    }

    assert %{"ok" => true, "snapshot" => %{"instruction" => "First value"}} =
             command_request(context.socket_path, "initial-request", command)

    assert :ok = Library.put_setting(context.library, "generation.instruction", "Later value")

    assert %{
             "ok" => true,
             "snapshot" => %{
               "instruction" => "Later value",
               "statusMessage" => "Command already applied"
             }
           } = command_request(context.socket_path, "retry-request", command)

    conflicting = Map.put(command, "instruction", "Conflicting value")

    assert %{
             "ok" => false,
             "requestId" => "conflict-request",
             "error" => %{"code" => "command_id_conflict"}
           } = command_request(context.socket_path, "conflict-request", conflicting)

    assert {:ok, "Later value"} =
             Library.get_setting(context.library, "generation.instruction")
  end

  test "reports a claimed command's crash window without repeating its mutation", context do
    command = %{
      "id" => "pending-command-id",
      "kind" => "updateInstruction",
      "instruction" => "Must not run"
    }

    command_hash =
      command
      |> RFC8785.encode!()
      |> Digest.sha256()

    assert {:ok, :execute} =
             Library.claim_command(context.library, command["id"], command_hash)

    assert %{
             "ok" => false,
             "requestId" => "pending-request",
             "error" => %{"code" => "command_outcome_unknown"}
           } = command_request(context.socket_path, "pending-request", command)

    assert :not_found = Library.get_setting(context.library, "generation.instruction")
  end

  test "requires a stable command identifier", context do
    assert %{
             "ok" => false,
             "requestId" => "missing-command-id",
             "error" => %{"code" => "invalid_command"}
           } =
             command_request(context.socket_path, "missing-command-id", %{
               "kind" => "updateInstruction",
               "instruction" => "Rejected"
             })
  end

  test "rejects duplicate JSON members and unknown request fields", context do
    duplicate =
      ~s({"version":1,"requestId":"one","requestId":"two","operation":"snapshot"})

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request_bytes(context.socket_path, duplicate)

    assert %{
             "ok" => false,
             "requestId" => "request-4",
             "error" => %{"code" => "invalid_request"}
           } =
             request(context.socket_path, %{
               "version" => 1,
               "requestId" => "request-4",
               "operation" => "snapshot",
               "secret" => "must-not-be-accepted"
             })
  end

  test "rejects a caller that knows only the socket path", context do
    assert %{
             "ok" => false,
             "requestId" => "wrong-auth",
             "error" => %{"code" => "authentication_required"}
           } =
             request(context.socket_path, %{
               "version" => 1,
               "requestId" => "wrong-auth",
               "operation" => "snapshot",
               "auth" => String.duplicate("b", 64)
             })

    assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
             request_bytes(
               context.socket_path,
               ~s({"version":1,"requestId":"missing-auth","operation":"snapshot"})
             )
  end

  test "does not replace a non-socket filesystem entry" do
    root = "/tmp/fs-u-#{System.unique_integer([:positive, :monotonic])}"

    path = Path.join(root, "core.sock")
    File.mkdir_p!(root)
    File.write!(path, "owner data")
    on_exit(fn -> File.rm_rf!(root) end)

    previous = Process.flag(:trap_exit, true)

    assert {:error, :unsafe_socket_path} =
             Server.start_link(path: path, token: @token, name: nil)

    Process.flag(:trap_exit, previous)
    assert File.read!(path) == "owner data"
  end

  test "refuses a symlinked socket directory without changing its target" do
    root = Path.join(System.tmp_dir!(), "fs-ipc-link-#{System.unique_integer([:positive])}")
    target = Path.join(root, "target")
    link = Path.join(root, "linked")
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)
    :ok = File.ln_s(target, link)
    on_exit(fn -> File.rm_rf!(root) end)

    previous = Process.flag(:trap_exit, true)

    assert {:error, :unsafe_socket_directory} =
             Server.start_link(path: Path.join(link, "core.sock"), token: @token, name: nil)

    Process.flag(:trap_exit, previous)
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o755
    refute File.exists?(Path.join(target, "core.sock"))
  end

  test "refuses a second listener without disturbing the live socket", context do
    previous = Process.flag(:trap_exit, true)

    assert {:error, :socket_already_active} =
             Server.start_link(path: context.socket_path, token: @token, name: nil)

    Process.flag(:trap_exit, previous)

    assert %{"ok" => true} =
             request(context.socket_path, %{
               "version" => 1,
               "requestId" => "still-live",
               "operation" => "snapshot"
             })
  end

  test "reports the authenticated outbox port without exposing identity", context do
    assert %{
             "ok" => true,
             "outbox" => %{"available" => false, "port" => nil}
           } =
             request(context.socket_path, %{
               "version" => 1,
               "requestId" => "outbox-status",
               "operation" => "outboxStatus"
             })
  end

  test "transient pairing admits a frame without a durable secret-bearing command", context do
    {:ok, supervisor} = Task.Supervisor.start_link()
    path = Path.join(Path.dirname(context.socket_path), "pair.sock")
    owner = self()

    pairer = fn bootstrap, _, request_id ->
      send(owner, {:physical_pair, bootstrap.device_id, request_id})
      {:ok, %{device_id: bootstrap.device_id}}
    end

    {:ok, server} =
      Server.start_link(
        path: path,
        token: @token,
        library: context.library,
        task_supervisor: supervisor,
        pairing: [
          resolver: {PairingResolver, %{}},
          pairer: pairer,
          fetcher: fn _, _ -> {:ok, @pairing_thing} end
        ],
        name: nil
      )

    on_exit(fn ->
      stop_process(server)
      stop_process(supervisor)
    end)

    bootstrap =
      Jason.encode!(%{
        "version" => 1,
        "deviceId" => @pairing_device_id,
        "serverSpki" => "sha256:" <> String.duplicate("b", 64),
        "secret" => Base.url_encode64(:binary.copy(<<37>>, 16), padding: false)
      })

    assert %{"ok" => true, "frame" => %{"frameId" => @pairing_device_id}} =
             request(path, %{
               "version" => 1,
               "requestId" => "pair-physical-1",
               "operation" => "pair",
               "bootstrap" => bootstrap,
               "discoveredId" => @pairing_device_id,
               "origin" => "https://frame.local",
               "credentialRef" => "keychain:pair-test"
             })

    assert_receive {:physical_pair, @pairing_device_id, "pair-physical-1"}

    assert %{"ok" => true, "snapshot" => %{"targets" => [%{"id" => @pairing_device_id}]}} =
             request(path, %{
               "version" => 1,
               "requestId" => "after-pair",
               "operation" => "snapshot"
             })

    assert :ok = Library.forget_paired_frame(context.library, @pairing_device_id)

    assert %{"ok" => true, "frame" => %{"frameId" => @pairing_device_id}} =
             request(path, %{
               "version" => 1,
               "requestId" => "recover-physical-1",
               "operation" => "recoverPair",
               "bootstrap" => bootstrap,
               "discoveredId" => @pairing_device_id,
               "origin" => "https://frame.local",
               "credentialRef" => "keychain:pair-test"
             })

    refute_receive {:physical_pair, _, _}
  end

  defp request(path, document) do
    document
    |> Map.put_new("auth", @token)
    |> RFC8785.encode!()
    |> then(&request_bytes(path, &1))
  end

  defp request_bytes(path, bytes) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [
        :binary,
        {:packet, 4},
        {:packet_size, 1024 * 1024},
        {:active, false}
      ])

    :ok = :gen_tcp.send(socket, bytes)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    Jason.decode!(response)
  end

  defp command_request(path, request_id, command) do
    request(path, %{
      "version" => 1,
      "requestId" => request_id,
      "operation" => "command",
      "command" => command
    })
  end

  defp stop_process(process) do
    GenServer.stop(process)
  catch
    :exit, _ -> :ok
  end
end
