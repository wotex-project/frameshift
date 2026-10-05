[root, actor, reference] = System.argv()
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, config} = Frameshift.Transport.ProtectedFile.configure("/var/lib/frameshift/credentials")
{:ok, _identity} = Frameshift.Transport.ProtectedFile.resolve(reference, config)
{:ok, library} = Frameshift.Library.start_link(name: nil, data_dir: root)

for {name, pixels} <- [
      {"original.png", <<255, 0, 0, 255, 0, 255, 0, 128>>},
      {"original.jpg", File.read!("/fixtures/canonical-jpeg.rgba")}
    ] do
  {:ok, %{"status" => "succeeded", "importedItemID" => id}} =
    Frameshift.Library.command_receipt_as(library, "ubuntu-" <> name, String.to_integer(actor))

  {:ok, %{"bytes" => bytes}} = Frameshift.Library.read_object(library, id)
  {:ok, %{rgba: ^pixels, original: original}} = Frameshift.MasterPackage.decode(bytes)
  if name == "original.jpg", do: true = original == File.read!("/fixtures/canonical-jpeg.jpg")
  {:ok, master} = Frameshift.Library.get_master(library, id)
  true = master["provenance_json"]["codecRevision"] == Frameshift.NativeCodec.revision()
end

:ok = GenServer.stop(library)
IO.puts("Restored exact original/pixel/receipt and protected identity readback passed")
