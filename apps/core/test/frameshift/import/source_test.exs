defmodule Frameshift.Import.SourceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Import.Source

  setup do
    directory =
      Path.join(System.tmp_dir!(), "import-source-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    path = Path.join(directory, "source.png")
    on_exit(fn -> File.rm_rf!(directory) end)
    %{path: path, directory: directory}
  end

  test "regular descriptor preserves exact digest, chunk bounds, resume offset and lifetime", %{
    path: path
  } do
    bytes = :binary.copy("abcdef", 2_049)
    File.write!(path, bytes)
    File.chmod!(path, 0o644)
    parent = self()

    assert :ok =
             Source.with_source(path, fn source ->
               assert source.filename == "source.png"
               assert source.count == byte_size(bytes)
               assert source.digest == Digest.sha256(bytes)
               assert {:ok, chunk} = Source.read_chunk(source, 0)
               assert byte_size(chunk) == 6_144
               assert {:ok, resumed} = Source.read_chunk(source, 6_145)
               assert resumed == binary_part(bytes, 6_145, 6_144)
               assert {:ok, last} = Source.read_chunk(source, byte_size(bytes) - 3)
               assert last == "def"
               assert :eof = Source.read_chunk(source, byte_size(bytes))
               assert {:error, :import_source_unavailable} = Source.read_chunk(source, -1)

               assert {:error, :import_source_unavailable} =
                        Source.read_chunk(source, byte_size(bytes) + 1)

               assert :ok = Source.verify(source)
               send(parent, {:descriptor, source.descriptor})
               :ok
             end)

    assert_receive {:descriptor, descriptor}
    assert {:error, _} = :file.read(descriptor, 1)
  end

  test "empty, oversized sparse, missing, directory and symlink paths refuse before callbacks", %{
    path: path,
    directory: directory
  } do
    callback = fn _ -> flunk("unsafe original admitted") end
    assert {:error, :import_source_unavailable} = Source.with_source(path, callback)
    assert {:error, :import_source_unavailable} = Source.with_source(directory, callback)
    File.write!(path, "")
    assert {:error, :import_source_unavailable} = Source.with_source(path, callback)
    File.write!(path, "V")
    link = path <> "-link"
    File.ln_s!(path, link)
    assert {:error, :import_source_unavailable} = Source.with_source(link, callback)
    {:ok, descriptor} = :file.open(String.to_charlist(path), [:raw, :binary, :write])
    {:ok, _} = :file.position(descriptor, 134_217_728)
    :ok = :file.write(descriptor, "x")
    :ok = :file.close(descriptor)
    assert {:error, :import_source_unavailable} = Source.with_source(path, callback)
  end

  test "same-inode byte edits, truncation and replacement refuse before finish", %{path: path} do
    for replacement <- ["abcdeg", "x", :replace_inode] do
      File.write!(path, "abcdef")

      assert {:error, :import_source_unavailable} =
               Source.with_source(path, fn source ->
                 if replacement == :replace_inode do
                   File.rename!(path, path <> "-old")
                   File.write!(path, "abcdef")
                 else
                   File.write!(path, replacement)
                 end

                 Source.verify(source)
               end)
    end
  end

  test "descriptor closes after callback refusal or exception", %{path: path} do
    File.write!(path, "V")
    parent = self()

    assert {:error, :fixture_refusal} =
             Source.with_source(path, fn source ->
               send(parent, {:descriptor, source.descriptor})
               {:error, :fixture_refusal}
             end)

    assert_receive {:descriptor, descriptor}
    assert {:error, _} = :file.read(descriptor, 1)

    assert_raise RuntimeError, "callback fixture", fn ->
      Source.with_source(path, fn source ->
        send(parent, {:descriptor, source.descriptor})
        raise "callback fixture"
      end)
    end

    assert_receive {:descriptor, descriptor}
    assert {:error, _} = :file.read(descriptor, 1)
  end
end
