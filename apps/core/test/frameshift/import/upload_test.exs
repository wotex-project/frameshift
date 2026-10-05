defmodule Frameshift.Import.UploadTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Frameshift.Digest
  alias Frameshift.Import.Intent
  alias Frameshift.Import.Upload
  alias Frameshift.Library
  alias Frameshift.MasterPackage

  @actor 501
  @codec_directory Path.expand("../../../../../codec", __DIR__)
  @codec Path.join(@codec_directory, "target/release/frameshift-codec")
  @fixture Path.expand("../../fixtures/native-codec-worker.c", __DIR__)

  setup_all do
    {output, status} =
      System.cmd("cargo", ["build", "--offline", "--locked", "--release"],
        cd: @codec_directory,
        stderr_to_stdout: true
      )

    assert status == 0, output

    directory =
      Path.join(System.tmp_dir!(), "upload-workers-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    worker = Path.join(directory, "worker")

    {output, status} =
      System.cmd("cc", ["-std=c99", "-Wall", "-Wextra", "-Werror", @fixture, "-o", worker],
        stderr_to_stdout: true
      )

    assert status == 0, output
    File.chmod!(worker, 0o500)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{worker: worker}
  end

  setup do
    Process.flag(:trap_exit, true)

    directory =
      Path.join(System.tmp_dir!(), "upload-library-#{System.unique_integer([:positive])}")

    library = start_supervised!({Library, name: nil, data_dir: directory})
    fence = Path.join(System.tmp_dir!(), "frameshift-import-custody")
    codec_fence = Path.join(System.tmp_dir!(), "frameshift-codec-custody")
    refute File.exists?(fence)
    refute File.exists?(codec_fence)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{library: library, fence: fence, codec_fence: codec_fence}
  end

  test "real PNG chunks join native normalization, exact provenance, SQLite and immutable replay",
       %{library: library} do
    owner = owner(library, @codec)
    original = png()
    intent = intent(original)

    assert {:ok, %{"uploadToken" => token, "offset" => 0} = began} =
             Upload.begin_upload(owner, intent, @actor)

    assert {:ok, ^began} = Upload.begin_upload(owner, intent, @actor)
    <<first::binary-size(12), rest::binary>> = original
    assert {:ok, %{"offset" => 12}} = Upload.append(owner, token, 0, Base.encode64(first), @actor)
    assert {:ok, %{"offset" => 12}} = Upload.begin_upload(owner, intent, @actor)
    assert {:ok, _} = Upload.append(owner, token, 12, Base.encode64(rest), @actor)

    assert {:ok, %{"status" => "succeeded", "importedItemID" => id} = receipt} =
             Upload.finish(owner, token, @actor)

    assert {:ok, %{"bytes" => package}} = Library.read_object(library, id)

    assert {:ok, %{original: ^original, rgba: <<255, 0, 0, 255, 0, 255, 0, 128>>}} =
             MasterPackage.decode(package)

    assert {:ok, master} = Library.get_master(library, id)
    provenance = master["provenance_json"]
    assert provenance["codecDigest"] == Digest.sha256(File.read!(@codec))
    assert provenance["originalFilename"] == "source.png"
    assert provenance["originalMediaType"] == "image/png"
    assert provenance["originalOrientation"] == 1
    assert provenance["colorInterpretation"] == "assumed-srgb"
    assert provenance["sourceDigest"] == Digest.sha256(original)
    assert :sys.get_state(owner).leases == %{}
    :ok = Library.remove_master(library, id)
    :ok = stop_supervised(Upload)
    unavailable = owner(library, nil)
    assert {:ok, ^receipt} = Upload.begin_upload(unavailable, intent, @actor)
    assert {:ok, %{"removed_at_ms" => removed}} = Library.get_master(library, id)
    assert is_integer(removed)
  end

  test "qualified JPEG bytes retain exact source, canonical pixels and media provenance", %{
    library: library
  } do
    owner = owner(library, @codec)
    original = File.read!(Path.expand("../../fixtures/canonical-jpeg.jpg", __DIR__))
    pixels = File.read!(Path.expand("../../fixtures/canonical-jpeg.rgba", __DIR__))
    intent = %{intent(original) | "originalFilename" => "art.jpg"}

    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent, @actor)
    assert {:ok, _} = Upload.append(owner, token, 0, Base.encode64(original), @actor)

    assert {:ok, %{"status" => "succeeded", "importedItemID" => id} = receipt} =
             Upload.finish(owner, token, @actor)

    assert {:ok, %{"bytes" => package}} = Library.read_object(library, id)

    assert {:ok, %{original: ^original, rgba: ^pixels, width: 32, height: 24}} =
             MasterPackage.decode(package)

    assert {:ok, master} = Library.get_master(library, id)
    provenance = master["provenance_json"]
    assert provenance["originalMediaType"] == "image/jpeg"
    assert provenance["originalFilename"] == "art.jpg"
    assert provenance["colorInterpretation"] == "assumed-srgb"
    assert provenance["codecRevision"] == Frameshift.NativeCodec.revision()
    assert provenance["sourceDigest"] == Digest.sha256(original)
    assert {:ok, ^receipt} = Upload.begin_upload(owner, intent, @actor)

    malformed = %{intent(<<255, 216, 255, 217>>) | "id" => "jpeg-refusal"}
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, malformed, @actor)

    assert {:ok, _} =
             Upload.append(owner, token, 0, Base.encode64(<<255, 216, 255, 217>>), @actor)

    assert {:error, :codec_malformed} = Upload.finish(owner, token, @actor)
    assert :not_found = Library.command_receipt_as(library, malformed["id"], @actor)
    assert {:ok, %{"status" => "cancelled"}} = Upload.cancel(owner, token, @actor)
  end

  test "actor, hash and token conflicts refuse before appending or claiming", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent(), @actor)
    assert {:error, :command_id_conflict} = Upload.begin_upload(owner, intent(), 502)

    assert {:error, :command_id_conflict} =
             Upload.begin_upload(owner, %{intent() | "title" => "other"}, @actor)

    assert {:error, :invalid_import_actor} = Upload.begin_upload(owner, intent(), nil)

    for actor <- [502, nil, -1] do
      assert {:error, :invalid_upload_token} = Upload.append(owner, token, 0, "Vg==", actor)
      assert {:error, :invalid_upload_token} = Upload.finish(owner, token, actor)
      assert {:error, :invalid_upload_token} = Upload.cancel(owner, token, actor)
    end

    assert {:error, :invalid_upload_token} =
             Upload.finish(owner, String.duplicate("a", 64), @actor)

    assert :not_found = Library.command_receipt_as(library, "upload-1", @actor)
    assert {:ok, %{"status" => "cancelled"}} = Upload.cancel(owner, token, @actor)
  end

  test "chunks refuse gaps, duplicates, overflow and noncanonical or excessive base64", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent("VV"), @actor)

    for {offset, bytes, reason} <- [
          {1, "Vg==", :invalid_import_offset},
          {-1, "Vg==", :invalid_import_offset},
          {0, "VlZW", :invalid_import_offset},
          {0, "Vg", :invalid_import_chunk},
          {0, "Vh==", :invalid_import_chunk},
          {0, "Vg==\n", :invalid_import_chunk},
          {0, "", :invalid_import_chunk},
          {0, Base.encode64(:binary.copy("x", 6_145)), :invalid_import_chunk}
        ] do
      assert {:error, ^reason} = Upload.append(owner, token, offset, bytes, @actor)
    end

    assert {:error, :import_incomplete} = Upload.finish(owner, token, @actor)
    assert {:ok, %{"offset" => 1}} = Upload.append(owner, token, 0, "Vg==", @actor)
    assert {:error, :invalid_import_offset} = Upload.append(owner, token, 0, "Vg==", @actor)
    assert {:ok, %{"offset" => 1}} = Upload.begin_upload(owner, intent("VV"), @actor)
    assert :not_found = Library.command_receipt_as(library, "upload-1", @actor)
  end

  test "two leases bound intake, generated file permissions and cancellation", %{
    library: library,
    worker: worker,
    fence: fence
  } do
    owner = owner(library, worker)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent(), @actor)
    assert {:ok, _} = Upload.begin_upload(owner, %{intent() | "id" => "second"}, @actor)

    assert {:error, :import_busy} =
             Upload.begin_upload(owner, %{intent() | "id" => "third"}, @actor)

    assert Bitwise.band(File.lstat!(fence).mode, 0o7777) == 0o700

    for file <- File.ls!(fence),
        do: assert(Bitwise.band(File.lstat!(Path.join(fence, file)).mode, 0o7777) == 0o600)

    assert {:ok, _} = Upload.cancel(owner, token, @actor)
    assert {:ok, _} = Upload.begin_upload(owner, %{intent() | "id" => "third"}, @actor)
    :ok = stop_supervised(Upload)
    refute File.exists?(fence)
  end

  test "idle and absolute expiration remove only known intake custody", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)

    for {field, age} <- [{:touched, 30_000}, {:created, 600_000}] do
      assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent(), @actor)

      :sys.replace_state(owner, fn state ->
        put_in(state, [:leases, token, field], System.monotonic_time(:millisecond) - age)
      end)

      send(owner, {:expire, token})
      assert {:error, :invalid_upload_token} = Upload.finish(owner, token, @actor)
      assert :sys.get_state(owner).leases == %{}
    end
  end

  test "mismatched source and decoder refusal create no Library claim and allow explicit cancellation",
       %{library: library, worker: worker} do
    owner = owner(library, worker)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent("V"), @actor)
    assert {:ok, _} = Upload.append(owner, token, 0, Base.encode64("F"), @actor)
    assert {:error, :import_source_mismatch} = Upload.finish(owner, token, @actor)
    assert {:ok, _} = Upload.cancel(owner, token, @actor)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent("F"), @actor)
    assert {:ok, _} = Upload.append(owner, token, 0, Base.encode64("F"), @actor)
    assert {:error, :codec_unsupported} = Upload.finish(owner, token, @actor)
    assert :not_found = Library.command_receipt_as(library, "upload-1", @actor)
    assert {:ok, _} = Upload.cancel(owner, token, @actor)
  end

  test "changed inode custody refuses appends and preserves the unknown replacement", %{
    library: library,
    worker: worker,
    fence: fence
  } do
    owner = owner(library, worker)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent(), @actor)
    stage = :sys.get_state(owner).leases[token].stage
    File.rename!(stage.path, stage.path <> "-abandoned")
    File.write!(stage.path, "unrelated")
    File.chmod!(stage.path, 0o600)
    assert {:error, :import_stage_unavailable} = Upload.append(owner, token, 0, "Vg==", @actor)
    assert {:error, :import_stage_unavailable} = Upload.cancel(owner, token, @actor)
    :ok = stop_supervised(Upload)
    assert File.read!(stage.path) == "unrelated"
    assert File.exists?(fence)
    File.rm_rf!(fence)
  end

  test "finishing retains its lease through deadlines and forbids competing finish/cancel", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)
    {token, _} = upload(owner, "S")
    caller = Task.async(fn -> Upload.finish(owner, token, @actor) end)
    assert eventually(fn -> :sys.get_state(owner).leases[token].phase == :finishing end)

    :sys.replace_state(owner, fn state ->
      put_in(state, [:leases, token, :created], System.monotonic_time(:millisecond) - 600_001)
    end)

    send(owner, {:expire, token})
    assert {:error, :import_busy} = Upload.cancel(owner, token, @actor)
    assert {:error, :import_busy} = Upload.finish(owner, token, @actor)
    assert {:error, :import_busy} = Upload.begin_upload(owner, intent("S"), @actor)
    assert {:ok, %{"status" => "succeeded"}} = Task.await(caller, 15_000)
  end

  test "a slow Library claim retains actual finish custody after an IPC-sized wait", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)
    {token, _} = upload(owner, "V")
    :sys.suspend(library)
    caller = Task.async(fn -> Upload.finish(owner, token, @actor) end)
    assert eventually(fn -> :sys.get_state(owner).leases[token].phase == :finishing end)
    Process.sleep(5_100)
    assert Process.alive?(:sys.get_state(owner).leases[token].task.pid)
    assert {:error, :import_busy} = Upload.cancel(owner, token, @actor)
    :sys.resume(library)
    assert {:ok, %{"status" => "succeeded"}} = Task.await(caller)
  end

  test "lost finish reply recovers durable result and never decodes on repeated begin", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)
    {token, intent} = upload(owner, "V")
    parent = self()

    spawn(fn ->
      :gen_server.send_request(owner, {:finish, token, @actor})
      send(parent, :finish_sent)
      Process.exit(self(), :kill)
    end)

    assert_receive :finish_sent
    assert eventually(fn -> :sys.get_state(owner).leases == %{} end)

    assert {:ok, %{"status" => "succeeded"} = receipt} =
             Library.command_receipt_as(library, intent["id"], @actor)

    assert {:ok, ^receipt} = Upload.begin_upload(owner, intent, @actor)
    assert :sys.get_state(owner).leases == %{}
  end

  test "pending, terminal failed and ordinary receipts do not allocate stages", %{
    library: library,
    worker: worker
  } do
    owner = owner(library, worker)
    intent = intent()
    {:ok, hash} = Intent.identity(intent)
    assert {:ok, :execute} = Library.claim_command_as(library, intent["id"], hash, @actor)
    assert {:error, :command_outcome_unknown} = Upload.begin_upload(owner, intent, @actor)

    assert :ok =
             Library.complete_command_as(
               library,
               intent["id"],
               hash,
               @actor,
               {:error, :library_storage_full}
             )

    assert {:error, "library_storage_full"} = Upload.begin_upload(owner, intent, @actor)
    ordinary = %{intent | "id" => "ordinary"}
    {:ok, ordinary_hash} = Intent.identity(ordinary)
    assert {:ok, :execute} = Library.claim_command_as(library, "ordinary", ordinary_hash, @actor)
    assert :ok = Library.complete_command_as(library, "ordinary", ordinary_hash, @actor, :ok)
    assert {:error, :command_id_conflict} = Upload.begin_upload(owner, ordinary, @actor)
    assert :sys.get_state(owner).leases == %{}
  end

  test "abrupt owner death preserves stages while replacement and ordinary Library reads stay available",
       %{library: library, worker: worker, fence: fence, codec_fence: codec_fence} do
    owner = owner(library, worker)
    {token, intent} = upload(owner, "V")
    path = :sys.get_state(owner).leases[token].stage.path
    codec = :sys.get_state(owner).codec
    Process.exit(owner, :kill)
    assert eventually(fn -> not Process.alive?(codec) end)
    assert File.read!(path) == "V"
    assert {:ok, replacement} = Upload.start_link(name: nil, library: library, codec_path: worker)
    assert {:error, :import_unavailable} = Upload.begin_upload(replacement, intent, @actor)
    assert Library.search(library, "") == []
    GenServer.stop(replacement)
    File.rm_rf!(fence)
    File.rm_rf!(codec_fence)
  end

  test "owner failure reports redact tokens, paths and private text", %{
    library: library,
    worker: worker,
    fence: fence
  } do
    owner = owner(library, worker)
    {token, _} = upload(owner, "V")
    secret = "private-upload-failure-context"
    logs = capture_log(fn -> GenServer.stop(owner, {:fixture_fault, secret}) end)
    refute logs =~ secret
    refute logs =~ token
    refute logs =~ fence
    assert logs =~ "import_owner_failure"
  end

  test "finish task loss fences custody while an already queued Library effect remains recoverable",
       %{
         library: library,
         worker: worker,
         fence: fence
       } do
    owner = owner(library, worker)
    {token, intent} = upload(owner, "V")
    :sys.suspend(library)
    caller = Task.async(fn -> Upload.finish(owner, token, @actor) end)

    assert eventually(fn ->
             {:messages, messages} = Process.info(library, :messages)

             Enum.any?(
               messages,
               &match?({:"$gen_call", _, {:import_master_command, _, _, _, _, _}}, &1)
             )
           end)

    task = :sys.get_state(owner).leases[token].task.pid
    secret = "private-task-failure-context"

    logs =
      capture_log(fn ->
        Process.exit(task, {:fixture_fault, secret})
        Process.sleep(50)
      end)

    refute logs =~ secret
    refute logs =~ token
    refute logs =~ fence
    assert {:error, :command_outcome_unknown} = Task.await(caller)
    assert {:error, :command_outcome_unknown} = Upload.cancel(owner, token, @actor)
    :sys.resume(library)

    assert {:ok, %{"status" => "succeeded"} = receipt} =
             Library.command_receipt_as(library, intent["id"], @actor)

    assert {:ok, ^receipt} = Upload.begin_upload(owner, intent, @actor)

    assert {:error, :import_unavailable} =
             Upload.begin_upload(owner, %{intent | "id" => "new"}, @actor)

    :ok = stop_supervised(Upload)
    assert File.exists?(fence)
    File.rm_rf!(fence)
  end

  defp owner(library, path),
    do:
      start_supervised!({Upload, library: library, codec_path: path, name: nil},
        restart: :temporary
      )

  defp upload(owner, bytes) do
    intent = intent(bytes)
    assert {:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent, @actor)
    assert {:ok, _} = Upload.append(owner, token, 0, Base.encode64(bytes), @actor)
    {token, intent}
  end

  defp intent(bytes \\ "V"),
    do: %{
      "kind" => "importOriginal",
      "id" => "upload-1",
      "title" => "Uploaded art",
      "originalFilename" => "source.png",
      "sourceByteCount" => byte_size(bytes),
      "sourceDigest" => Digest.sha256(bytes)
    }

  defp eventually(function, attempts \\ 200)
  defp eventually(_, 0), do: false

  defp eventually(function, attempts),
    do:
      if(function.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(function, attempts - 1)
          )
      )

  defp png do
    <<137, "PNG\r\n", 26, 10>> <>
      chunk("IHDR", <<2::32, 1::32, 8, 6, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(<<0, 255, 0, 0, 255, 0, 255, 0, 128>>)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, bytes),
    do: <<byte_size(bytes)::32, type::binary, bytes::binary, :erlang.crc32(type <> bytes)::32>>
end
