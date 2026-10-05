Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

alias Frameshift.Digest
alias Frameshift.LocalIPC.Client

path = "/tmp/import-socket/c.sock"
policy = [uid: 65_534, gid: 50]

request = fn operation, fields ->
  Map.merge(fields, %{
    "version" => 1,
    "requestId" => "import-fixture",
    "auth" => "peer",
    "operation" => operation
  })
end

exchange = fn operation, fields ->
  Client.exchange(path, request.(operation, fields), :command, policy)
end

chunk = fn type, bytes ->
  <<byte_size(bytes)::32, type::binary, bytes::binary, :erlang.crc32(type <> bytes)::32>>
end

original =
  <<137, "PNG\r\n", 26, 10>> <>
    chunk.("IHDR", <<2::32, 1::32, 8, 6, 0, 0, 0>>) <>
    chunk.("IDAT", :zlib.compress(<<0, 255, 0, 0, 255, 0, 255, 0, 128>>)) <> chunk.("IEND", <<>>)

intent = %{
  "kind" => "importOriginal",
  "id" => "linux-upload-1",
  "title" => "Linux original",
  "originalFilename" => "original.png",
  "sourceByteCount" => byte_size(original),
  "sourceDigest" => Digest.sha256(original)
}

if System.argv() == ["other-actor"] do
  {:ok, %{"ok" => false, "error" => %{"code" => "command_id_conflict"}}} =
    exchange.("importBegin", %{"intent" => intent})

  {:ok, %{"ok" => false, "error" => %{"code" => "command_id_conflict"}}} =
    exchange.("importStatus", %{"commandId" => intent["id"]})

  IO.puts("actor-conflict-passed")
  System.halt(0)
end

{:ok, %{"ok" => true, "import" => %{"uploadToken" => token, "offset" => 0}}} =
  exchange.("importBegin", %{"intent" => intent})

{:ok, %{"ok" => false, "error" => %{"code" => "invalid_import_offset"}}} =
  exchange.("importChunk", %{
    "uploadToken" => token,
    "offset" => 1,
    "bytes" => Base.encode64(original)
  })

{:ok, %{"ok" => false, "error" => %{"code" => "invalid_request"}}} =
  exchange.("importFinish", %{"uploadToken" => token, "actor" => 0})

{:ok, %{"ok" => false, "error" => %{"code" => "operation_unavailable"}}} =
  exchange.("command", %{
    "command" => %{"kind" => "importFile", "id" => "forbidden", "importPath" => "/private"}
  })

{:ok, %{"ok" => true, "import" => %{"offset" => offset}}} =
  exchange.("importChunk", %{
    "uploadToken" => token,
    "offset" => 0,
    "bytes" => Base.encode64(original)
  })

true = offset == byte_size(original)

{:ok, %{"ok" => true, "import" => %{"importedItemID" => id} = receipt}} =
  exchange.("importFinish", %{"uploadToken" => token})

true = Digest.valid_sha256?(id)
{:ok, %{"ok" => true, "import" => ^receipt}} = exchange.("importBegin", %{"intent" => intent})

{:ok, %{"ok" => true, "import" => ^receipt}} =
  exchange.("importStatus", %{"commandId" => intent["id"]})

{:ok, %{"ok" => false, "error" => %{"code" => "command_id_conflict"}}} =
  exchange.("importBegin", %{"intent" => %{intent | "title" => "changed"}})

IO.puts("authenticated-import-passed")
