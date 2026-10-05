{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, library} = Frameshift.Library.start_link(name: nil, data_dir: "/var/lib/frameshift")
[actor] = System.argv()
actor = String.to_integer(actor)

for {name, expected} <- [
      {"original.png", <<255, 0, 0, 255, 0, 255, 0, 128>>},
      {"original.jpg", File.read!("/fixtures/canonical-jpeg.rgba")}
    ] do
  {:ok, %{"status" => "succeeded", "importedItemID" => id}} =
    Frameshift.Library.command_receipt_as(library, "ubuntu-" <> name, actor)

  {:ok, %{"bytes" => package}} = Frameshift.Library.read_object(library, id)
  {:ok, %{rgba: ^expected, original: original}} = Frameshift.MasterPackage.decode(package)
  {:ok, master} = Frameshift.Library.get_master(library, id)
  true = Frameshift.NativeCodec.revision() == master["provenance_json"]["codecRevision"]
  media = if name == "original.jpg", do: "image/jpeg", else: "image/png"
  ^media = master["provenance_json"]["originalMediaType"]
  if name == "original.jpg", do: true = original == File.read!("/fixtures/canonical-jpeg.jpg")
end

connection = :sys.get_state(library).connection

%{rows: [["3.53.4", "ok"]]} =
  Exqlite.query!(
    connection,
    "SELECT sqlite_version(), (SELECT integrity_check FROM pragma_integrity_check)"
  )

:ok = GenServer.stop(library)
IO.puts("Exact SQLite/original/pixel/codec readback passed")
