Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

Code.prepend_paths(["/opt/exile/ebin", "/opt/exqlite/ebin"])
{:ok, _} = Application.ensure_all_started(:exile)
{:ok, _} = Application.ensure_all_started(:exqlite)

alias Frameshift.Digest
alias Frameshift.Import.Upload
alias Frameshift.Library

{:ok, tasks} = Task.Supervisor.start_link(max_children: 64)
{:ok, library} = Library.start_link(name: nil, data_dir: Path.join(System.tmp_dir!(), "library"))

{:ok, owner} =
  Upload.start_link(
    name: nil,
    library: library,
    task_supervisor: tasks,
    codec_path: "/usr/local/bin/frameshift-codec"
  )

original = :binary.copy("x", 6_144)

intent = %{
  "kind" => "importOriginal",
  "id" => "full-disk",
  "title" => "Intake refusal",
  "originalFilename" => "source.png",
  "sourceByteCount" => byte_size(original),
  "sourceDigest" => Digest.sha256(original)
}

{:ok, %{"uploadToken" => token}} = Upload.begin_upload(owner, intent, 1)
filler = Path.join(System.tmp_dir!(), "filler")
{:ok, descriptor} = :file.open(String.to_charlist(filler), [:raw, :binary, :write, :exclusive])

fill = fn fill, count, remaining ->
  if remaining == 0, do: raise("fixture must exhaust its bounded tmpfs")

  case :file.write(descriptor, :binary.copy("x", count)) do
    :ok -> fill.(fill, count, remaining - 1)
    {:error, :enospc} when count > 4_096 -> fill.(fill, 4_096, remaining - 1)
    {:error, :enospc} -> :ok
  end
end

fill.(fill, 1_048_576, 1_024)
:ok = :file.close(descriptor)
{:error, :import_stage_unavailable} = Upload.append(owner, token, 0, Base.encode64(original), 1)
0 = :sys.get_state(owner).leases[token].stage.offset
{:error, :import_stage_unavailable} = Upload.append(owner, token, 0, Base.encode64(original), 1)
:not_found = Library.command_receipt_as(library, "full-disk", 1)
:ok = File.rm(filler)
{:ok, %{"status" => "cancelled"}} = Upload.cancel(owner, token, 1)
:ok = GenServer.stop(owner)
:ok = GenServer.stop(library)
IO.puts("actual-enospc-import-refusal-passed")
