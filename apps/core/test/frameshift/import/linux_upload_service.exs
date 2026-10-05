Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

Code.prepend_paths(["/opt/exile/ebin", "/opt/exqlite/ebin"])
{:ok, _} = Application.ensure_all_started(:exile)
{:ok, _} = Application.ensure_all_started(:exqlite)

alias Frameshift.Import.Upload
alias Frameshift.Library

{:ok, tasks} = Task.Supervisor.start_link(max_children: 64)
{:ok, library} = Library.start_link(name: nil, data_dir: "/tmp/import-service/library")

{:ok, upload} =
  Upload.start_link(
    name: nil,
    library: library,
    task_supervisor: tasks,
    codec_path: "/usr/local/bin/frameshift-codec"
  )

{:ok, socket} =
  Frameshift.LocalIPC.Server.start_link(
    name: nil,
    path: "/tmp/import-socket/c.sock",
    group_gid: 50,
    library: library,
    task_supervisor: tasks,
    upload_owner: upload
  )

connection = :sys.get_state(library).connection

%{rows: [["3.53.4", 1, 1, "ok"]]} =
  Exqlite.query!(
    connection,
    "SELECT sqlite_version(), sqlite_compileoption_used('ENABLE_FTS5'), sqlite_compileoption_used('THREADSAFE=1'), (SELECT integrity_check FROM pragma_integrity_check)"
  )

File.write!("/tmp/import-control/ready", "ready")

wait = fn wait ->
  if File.exists?("/tmp/import-control/stop"),
    do: :ok,
    else:
      (
        Process.sleep(10)
        wait.(wait)
      )
end

wait.(wait)

{:ok, %{"status" => "succeeded", "importedItemID" => id}} =
  Library.command_receipt_as(library, "linux-upload-1", 1)

{:error, :command_id_conflict} = Library.command_receipt_as(library, "linux-upload-1", 65_534)
{:ok, %{"bytes" => package}} = Library.read_object(library, id)

{:ok, %{original: original, rgba: <<255, 0, 0, 255, 0, 255, 0, 128>>}} =
  Frameshift.MasterPackage.decode(package)

true = byte_size(original) > 32

{:ok, %{"status" => "succeeded", "importedItemID" => ^id}} =
  Library.command_receipt_as(library, "linux-cli-1", 1)

:not_found = Library.command_receipt_as(library, "missing-source", 1)
14 = length(Library.audit_page(library)["entries"])
{:ok, %{"title" => "Linux original"}} = Library.get_master(library, id)

{:ok, %{"status" => "succeeded", "importedItemID" => jpeg_id}} =
  Library.command_receipt_as(library, "linux-upload-jpeg", 1)

{:ok, %{"status" => "succeeded", "importedItemID" => ^jpeg_id}} =
  Library.command_receipt_as(library, "linux-cli-jpeg", 1)

{:error, :command_id_conflict} = Library.command_receipt_as(library, "linux-cli-jpeg", 65_534)
{:ok, %{"bytes" => jpeg_package}} = Library.read_object(library, jpeg_id)

{:ok, %{original: jpeg, rgba: rgba, width: 32, height: 24}} =
  Frameshift.MasterPackage.decode(jpeg_package)

true = jpeg == File.read!("/src/test/fixtures/canonical-jpeg.jpg")
true = rgba == File.read!("/src/test/fixtures/canonical-jpeg.rgba")
{:ok, jpeg_master} = Library.get_master(library, jpeg_id)
"image/jpeg" = jpeg_master["provenance_json"]["originalMediaType"]
true = Frameshift.NativeCodec.revision() == jpeg_master["provenance_json"]["codecRevision"]
:ok = GenServer.stop(socket)
:ok = GenServer.stop(upload)
:ok = GenServer.stop(library)

{:ok, restarted} = Library.start_link(name: nil, data_dir: "/tmp/import-service/library")

{:ok, %{"status" => "succeeded", "importedItemID" => ^id}} =
  Library.command_receipt_as(restarted, "linux-upload-1", 1)

:ok = GenServer.stop(restarted)
IO.puts("fresh-sqlite-import-passed")
