Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

alias Frameshift.Digest
alias Frameshift.LocalIPC.Client

System.put_env("FRAMESHIFT_SERVICE_UID", "65534")
System.put_env("FRAMESHIFT_CONTROL_GID", "50")
System.put_env("FRAMESHIFT_SOCKET_PATH", "/tmp/import-socket/c.sock")

paths =
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))

entry =
  "true = is_nil(Process.whereis(Frameshift.Library)); " <>
    "{status, output, error} = Frameshift.CLI.run(System.argv()); " <>
    "true = is_nil(Process.whereis(Frameshift.Library)); " <>
    "IO.write(output); IO.write(:stderr, error); System.halt(status)"

cli = fn arguments ->
  System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", entry, "--"] ++ arguments,
    stderr_to_stdout: true
  )
end

if System.argv() == ["recovery"] do
  {output, 0} = cli.(["import-status", "linux-cli-1"])

  {:ok, %{"import" => %{"status" => "succeeded", "importedItemID" => id}}} =
    Wotex.JSON.decode(output)

  true = Digest.valid_sha256?(id)
  {jpeg_output, 0} = cli.(["import-status", "linux-cli-jpeg"])

  {:ok, %{"import" => %{"status" => "succeeded", "importedItemID" => jpeg_id}}} =
    Wotex.JSON.decode(jpeg_output)

  true = Digest.valid_sha256?(jpeg_id)
  IO.puts("fresh-vm-import-recovery-passed")

  System.halt(0)
end

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

directory = "/tmp/caller-original"
File.mkdir!(directory)
File.chmod!(directory, 0o700)
file = Path.join(directory, "original.png")
File.write!(file, original)
File.chmod!(file, 0o600)
{output, 0} = cli.(["import", file, "--title", "CLI original", "--id", "linux-cli-1"])
{:ok, %{"import" => %{"importedItemID" => ^id} = cli_receipt}} = Wotex.JSON.decode(output)
false = String.contains?(output, directory)
false = String.contains?(output, "uploadToken")
{output, 0} = cli.(["import", file, "--title", "CLI original", "--id", "linux-cli-1"])
{:ok, %{"import" => ^cli_receipt}} = Wotex.JSON.decode(output)
{output, 2} = cli.(["import", file, "--title", "changed", "--id", "linux-cli-1"])
true = String.contains?(output, "command_id_conflict")
File.rm!(file)
{output, 0} = cli.(["import-status", "linux-cli-1"])
{:ok, %{"import" => ^cli_receipt}} = Wotex.JSON.decode(output)
{output, 69} = cli.(["import", file, "--id", "missing-source"])
false = String.contains?(output, directory)
jpeg = File.read!("/src/test/fixtures/canonical-jpeg.jpg")

jpeg_intent = %{
  "kind" => "importOriginal",
  "id" => "linux-upload-jpeg",
  "title" => "Linux JPEG",
  "originalFilename" => "art.jpg",
  "sourceByteCount" => byte_size(jpeg),
  "sourceDigest" => Digest.sha256(jpeg)
}

{:ok, %{"ok" => true, "import" => %{"uploadToken" => jpeg_token}}} =
  exchange.("importBegin", %{"intent" => jpeg_intent})

{:ok, %{"ok" => true}} =
  exchange.("importChunk", %{
    "uploadToken" => jpeg_token,
    "offset" => 0,
    "bytes" => Base.encode64(jpeg)
  })

{:ok, %{"ok" => true, "import" => %{"importedItemID" => jpeg_id}}} =
  exchange.("importFinish", %{"uploadToken" => jpeg_token})

jpeg_file = Path.join(directory, "art.jpg")
File.write!(jpeg_file, jpeg)
File.chmod!(jpeg_file, 0o600)
{output, 0} = cli.(["import", jpeg_file, "--title", "CLI JPEG", "--id", "linux-cli-jpeg"])
{:ok, %{"import" => %{"importedItemID" => ^jpeg_id} = jpeg_receipt}} = Wotex.JSON.decode(output)
File.rm!(jpeg_file)
{output, 0} = cli.(["import-status", "linux-cli-jpeg"])
{:ok, %{"import" => ^jpeg_receipt}} = Wotex.JSON.decode(output)
IO.puts("fresh-cli-jpeg-import-passed")
File.rmdir!(directory)
IO.puts("fresh-cli-original-import-passed")

{:ok, %{"ok" => true}} =
  exchange.("command", %{
    "command" => %{
      "kind" => "updateInstruction",
      "id" => "ordinary-command",
      "instruction" => "Still artwork"
    }
  })

{output, 2} = cli.(["import-status", "ordinary-command"])
true = String.contains?(output, "command_id_conflict")
