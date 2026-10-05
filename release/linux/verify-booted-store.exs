defmodule FrameshiftBootedStoreFixture do
  @moduledoc false

  def run do
    [root, actor, reference, jpeg] = System.argv()
    {:ok, _} = Application.ensure_all_started(:exqlite)

    {:ok, config} =
      Frameshift.Transport.ProtectedFile.configure("/var/lib/frameshift/credentials")

    {:ok, _} = Frameshift.Transport.ProtectedFile.resolve(reference, config)
    {:ok, library} = Frameshift.Library.start_link(name: nil, data_dir: root)

    for {name, pixels, original, media} <- [
          {"systemd-fresh-absolute", <<255, 0, 0, 255, 0, 255, 0, 128>>,
           File.read!(Path.rootname(jpeg) <> ".png"), "image/png"},
          {"systemd-fresh-literal", <<255, 0, 0, 255, 0, 255, 0, 128>>,
           File.read!(Path.rootname(jpeg) <> ".png"), "image/png"},
          {"systemd-fresh-jpeg", File.read!(Path.rootname(jpeg) <> ".rgba"), File.read!(jpeg),
           "image/jpeg"}
        ] do
      {:ok, %{"status" => "succeeded", "importedItemID" => id}} =
        Frameshift.Library.command_receipt_as(library, name, String.to_integer(actor))

      {:ok, %{"bytes" => bytes}} = Frameshift.Library.read_object(library, id)
      {:ok, %{rgba: ^pixels, original: ^original}} = Frameshift.MasterPackage.decode(bytes)
      {:ok, master} = Frameshift.Library.get_master(library, id)
      true = master["provenance_json"]["codecRevision"] == Frameshift.NativeCodec.revision()
      ^media = master["provenance_json"]["originalMediaType"]
    end

    :ok = GenServer.stop(library)
    IO.puts("restored exact PNG/JPEG/receipt and separately retained identity passed")
  end
end

FrameshiftBootedStoreFixture.run()
