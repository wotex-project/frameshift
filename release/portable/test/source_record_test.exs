defmodule FrameshiftRelease.SourceRecordTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias FrameshiftRelease.{Input, RecordJSON, SourceRecord}

  setup_all do
    corpus =
      case System.get_env("FRAMESHIFT_SOURCE_ORACLE") do
        nil ->
          {node, 0} = System.cmd("mise", ["which", "node"])
          oracle = Path.expand("fixtures/source-oracle.mjs", __DIR__)
          {bytes, 0} = System.cmd(String.trim(node), [oracle])
          :json.decode(bytes)

        path ->
          {:ok, bytes} = Input.read(path, maximum: 2 * 1024 * 1024, worker: worker())
          :json.decode(bytes)
      end

    %{corpus: corpus}
  end

  setup %{corpus: c} do
    root = Path.join(System.tmp_dir!(), "frameshift-source-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "source-inputs.json")
    File.write!(path, Base.decode64!(c["message"]))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: path}
  end

  test "actual Git Mix collector bytes preserve Unicode modes and lock projection", %{
    corpus: c,
    path: path
  } do
    message = Base.decode64!(c["message"])
    assert {:ok, record} = SourceRecord.parse(message, c["tag"], c["commit"])
    assert record == c["record"]
    assert Enum.any?(record["files"], &(&1["path"] == "Ω/draw🖼.md"))
    assert Enum.any?(record["files"], &(&1["path"] == "executable" and &1["mode"] == "100755"))
    assert record["dependencyLocks"] == ["apps/core/mix.lock"]
    before = File.stat!(path)
    assert {:ok, ^record} = with_record(path, c, & &1)

    assert Map.drop(Map.from_struct(before), [:atime]) ==
             Map.drop(Map.from_struct(File.stat!(path)), [:atime])
  end

  test "wrong coordinates digest numeric fields paths and lock schema refuse", %{
    corpus: c,
    path: path
  } do
    message = Base.decode64!(c["message"])

    for {tag, commit} <- [
          {"v1.2.4", c["commit"]},
          {"v01.2.3", c["commit"]},
          {"v1.2.3-dev", c["commit"]},
          {c["tag"], String.duplicate("0", 40)}
        ] do
      assert {:error, :source_refused} = SourceRecord.parse(message, tag, commit)
    end

    assert {:error, :source_refused} =
             SourceRecord.with_record(
               path,
               String.duplicate("0", 64),
               c["tag"],
               c["commit"],
               & &1,
               worker: worker()
             )

    {:ok, {:object, fields}} = RecordJSON.decode(message, 8 * 1024 * 1024)
    files = Map.new(fields)["files"]
    {:object, first} = hd(files)
    child = {:object, List.keyreplace(first, "path", 0, {"path", ".mise.toml/extra"})}
    conflicting = Enum.sort_by([child | files], fn {:object, pairs} -> Map.new(pairs)["path"] end)

    missing =
      Enum.reject(files, fn {:object, pairs} -> Map.new(pairs)["path"] == ".mise.toml" end)

    inventories = [[hd(files) | files], conflicting, missing]

    numeric =
      for bytes <- [true, -1, 9_007_199_254_740_992],
          do: [{:object, List.keyreplace(first, "bytes", 0, {"bytes", bytes})} | tl(files)]

    structured =
      for inventory <- inventories ++ numeric,
          do:
            RecordJSON.encode(
              {:object, List.keyreplace(fields, "files", 0, {"files", inventory})}
            )

    for bytes <-
          structured ++
            [
              message <> "\n",
              " " <> message,
              String.replace(message, "\"schemaVersion\":1", "\"schemaVersion\":true"),
              String.replace(message, "\"schemaVersion\":1", "\"schemaVersion\":1.0"),
              String.replace(
                message,
                "\"schemaVersion\":1",
                "\"schemaVersion\":1,\"schemaVersion\":1"
              ),
              String.replace(message, "\"tree\":\"", "\"tree\":\"Z"),
              String.replace(message, "\"path\":\"executable\"", "\"path\":\"../executable\""),
              String.replace(message, "\"mode\":\"100755\"", "\"mode\":\"120000\""),
              String.replace(
                message,
                "\"dependencyLocks\":[\"apps/core/mix.lock\"]",
                "\"dependencyLocks\":[]"
              ),
              String.replace(message, "none", "release"),
              String.replace(message, "Ω", "\\u03a9")
            ] do
      assert bytes != message
      assert {:error, :source_refused} = SourceRecord.parse(bytes, c["tag"], c["commit"])
      File.write!(path, bytes)
      digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      assert {:error, :source_refused} = with_record(path, Map.put(c, "digest", digest), & &1)
    end

    assert {:error, :source_refused} =
             SourceRecord.parse(:binary.copy("x", 8 * 1024 * 1024 + 1), c["tag"], c["commit"])
  end

  test "private file parent aliases FIFOs and consumer-time mutation cannot accept", %{
    corpus: c,
    path: path,
    root: root
  } do
    for mode <- [0o400, 0o644, 0o666] do
      File.chmod!(path, mode)
      assert {:error, :source_refused} = with_record(path, c, & &1)
    end

    File.chmod!(path, 0o600)
    File.chmod!(root, 0o755)
    assert {:error, :source_refused} = with_record(path, c, & &1)
    File.chmod!(root, 0o700)
    File.ln_s!(path, Path.join(root, "alias"))
    assert {:error, :source_refused} = with_record(Path.join(root, "alias"), c, & &1)
    File.ln!(path, Path.join(root, "hardlink"))
    assert {:error, :source_refused} = with_record(path, c, & &1)
    File.rm!(Path.join(root, "hardlink"))
    assert {_, 0} = System.cmd("mkfifo", [Path.join(root, "fifo")])
    assert {:error, :source_refused} = with_record(Path.join(root, "fifo"), c, & &1)

    assert {:error, :input_refused} =
             with_record(path, c, fn _ ->
               File.write!(path, Base.decode64!(c["message"]))
               :must_not_accept
             end)

    assert {:error, :source_refused} = with_record(path, c, fn _ -> File.chmod!(root, 0o755) end)
    File.chmod!(root, 0o700)
    assert {:error, :source_refused} = with_record(path, c, fn _ -> raise "consumer fixture" end)
    assert {:ok, _} = with_record(path, c, & &1)
  end

  defp with_record(path, c, consumer),
    do:
      SourceRecord.with_record(path, c["digest"], c["tag"], c["commit"], consumer,
        worker: worker()
      )

  defp worker,
    do:
      System.get_env("FRAMESHIFT_RELEASE_INPUT_WORKER") ||
        Path.expand("../worker/zig-out/bin/frameshift-release-input", __DIR__)
end
