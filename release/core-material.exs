defmodule Frameshift.Release.CoreMaterialParser do
  @moduledoc """
  Parses already admitted dependency inputs without fetching or extracting files.

  The Node release consumer supplies bounded bytes on standard input. `lock` accepts
  only a literal core Mix lock with the supported Hex and exact Git forms. `package`
  serves both core and Gleam source admission using Hex 2.5.1's memory parser and
  inventories archive members, including types
  that memory extraction would otherwise omit. `manifest` accepts only the current
  binary Hex manifest schema; legacy text is deliberately refused.

  Compressed packages and expanded source have explicit size ceilings. Member paths,
  duplicates, special files and reserved generated manifests are checked before any
  facts leave this process. Output contains identities and hashes, never source bytes.
  The caller owns descriptor custody, Git blob comparison, source freezing, deadlines
  and private receipt persistence. These facts establish agreement with approved
  locks, not publisher trust, license rights or compiler authenticity.
  """

  @expanded 128 * 1024 * 1024

  def run([operation]) when operation in ["lock", "package", "manifest"] do
    :ok = Application.load(:hex)
    ~c"2.5.1" = Application.spec(:hex, :vsn)
    limit = if operation == "package", do: 64 * 1024 * 1024, else: 64 * 1024
    bytes = IO.binread(:stdio, limit + 1)
    true = is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= limit

    result =
      case operation do
        "lock" -> lock(bytes)
        "package" -> package(bytes)
        "manifest" -> manifest(bytes)
      end

    IO.binwrite(:stdio, [:json.encode(result), "\n"])
  end

  defp lock(bytes) do
    {:ok, {:%{}, _, pairs} = ast} = Code.string_to_quoted(bytes, emit_warnings: false)
    true = Macro.quoted_literal?(ast)
    true = length(pairs) in 1..128
    {lock, []} = Code.eval_quoted(ast)
    true = map_size(lock) == length(pairs)

    lock
    |> Enum.map(fn
      {key, {:hex, name, version, inner, managers, deps, "hexpm", outer}}
      when is_atom(key) and is_atom(name) and is_list(deps) ->
        %{
          type: "hex",
          key: name!(key),
          name: name!(name),
          version: version!(version),
          inner: digest!(inner),
          outer: digest!(outer),
          repo: "hexpm",
          managers: managers!(managers)
        }

      {key, {:git, url, commit, options}} when is_atom(key) and is_list(options) ->
        true =
          is_binary(url) and byte_size(url) <= 512 and
            Regex.match?(~r/\Ahttps:\/\/[A-Za-z0-9_.\/-]+\z/, url)

        true = is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)

        true =
          Keyword.keyword?(options) and
            length(options) == length(Enum.uniq_by(options, &elem(&1, 0)))

        true = Enum.all?(Keyword.keys(options), &(&1 in [:ref, :sparse]))
        ^commit = Keyword.fetch!(options, :ref)
        sparse = Keyword.get(options, :sparse, "")
        if sparse != "", do: path!(sparse)
        %{type: "git", key: name!(key), url: url, commit: commit, sparse: sparse}
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp package(bytes) do
    {:ok, outer_entries} = :mix_hex_erl_tar.table({:binary, bytes}, [:verbose])
    true = length(outer_entries) == 4
    true = Enum.all?(outer_entries, fn {_, type, _, _, _, _, _} -> type == :regular end)
    outer_names = Enum.map(outer_entries, fn {name, _, _, _, _, _, _} -> List.to_string(name) end)
    true = Enum.sort(outer_names) == ["CHECKSUM", "VERSION", "contents.tar.gz", "metadata.config"]

    {:ok, outer_files} =
      :mix_hex_erl_tar.extract({:binary, bytes}, [:memory, {:max_size, 64 * 1024 * 1024}])

    outer = Map.new(outer_files, fn {path, value} -> {List.to_string(path), value} end)
    true = byte_size(outer["metadata.config"]) <= 1024 * 1024
    raw = inflate(outer["contents.tar.gz"])
    {:ok, entries} = :mix_hex_erl_tar.table({:binary, raw}, [:verbose])
    true = length(entries) in 1..8192

    paths =
      Enum.map(entries, fn {name, type, _, _, _, _, _} ->
        true = type in [:regular, :directory]
        path!(String.trim_trailing(List.to_string(name), "/"))
      end)

    true = length(paths) == length(Enum.uniq(paths))

    config =
      :mix_hex_core.default_config()
      |> Map.put(:tarball_max_size, 64 * 1024 * 1024)
      |> Map.put(:tarball_max_uncompressed_size, @expanded)

    {:ok, unpacked} = :mix_hex_tarball.unpack(bytes, :memory, config)
    contents = Map.new(unpacked.contents, fn {path, value} -> {List.to_string(path), value} end)
    true = map_size(contents) == length(unpacked.contents)

    files =
      Enum.flat_map(entries, fn
        {name, :regular, size, _, mode, _, _} ->
          path = path!(List.to_string(name))
          mode = Bitwise.band(mode, 0o7777)

          true =
            path not in [".hex", "hex_metadata.config"] and
              Bitwise.band(mode, 0o7002) == 0 and Bitwise.band(mode, 0o400) != 0

          value = Map.fetch!(contents, path)
          true = byte_size(value) == size
          [%{path: path, mode: mode, bytes: size, sha256: sha(value)}]

        {_, :directory, 0, _, _, _, _} ->
          []
      end)

    %{
      name: name!(unpacked.metadata["name"]),
      version: version!(unpacked.metadata["version"]),
      inner: hex(unpacked.inner_checksum),
      outer: hex(unpacked.outer_checksum),
      metadata: %{
        bytes: byte_size(outer["metadata.config"]),
        sha256: sha(outer["metadata.config"])
      },
      parser: %{
        hex: "2.5.1",
        modules:
          Enum.map([Hex.SCM, :mix_hex_tarball, :mix_hex_erl_tar], fn module ->
            {^module, object, _} = :code.get_object_code(module)
            %{name: Atom.to_string(module), sha256: sha(object)}
          end)
      },
      directories:
        Enum.flat_map(entries, fn
          {name, :directory, 0, _, _, _, _} ->
            [path!(String.trim_trailing(List.to_string(name), "/"))]

          {_, :regular, _, _, _, _, _} ->
            []
        end)
        |> Enum.sort(),
      files: Enum.sort_by(files, & &1.path)
    }
  end

  defp inflate(bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      chunks = inflate_chunks(z, :zlib.safeInflate(z, bytes), 0, [])
      :ok = :zlib.inflateEnd(z)
      IO.iodata_to_binary(Enum.reverse(chunks))
    after
      :zlib.close(z)
    end
  end

  defp inflate_chunks(z, {status, output}, size, chunks) when status in [:continue, :finished] do
    size = size + IO.iodata_length(output)
    true = size <= @expanded

    if status == :finished,
      do: [output | chunks],
      else: inflate_chunks(z, :zlib.safeInflate(z, []), size, [output | chunks])
  end

  defp manifest(bytes) do
    {{:hex, 2, 0}, value} = :erlang.binary_to_term(bytes, [:safe])

    true =
      Enum.sort(Map.keys(value)) == [
        :inner_checksum,
        :managers,
        :name,
        :outer_checksum,
        :repo,
        :version
      ]

    "hexpm" = value.repo

    %{
      name: name!(value.name),
      version: version!(value.version),
      inner: digest!(value.inner_checksum),
      outer: digest!(value.outer_checksum),
      repo: value.repo,
      managers: managers!(value.managers)
    }
  end

  defp managers!(values) do
    true = is_list(values) and length(values) <= 3 and length(values) == length(Enum.uniq(values))
    true = Enum.all?(values, &(&1 in [:mix, :rebar3, :make]))
    Enum.sort(Enum.map(values, &Atom.to_string/1))
  end

  defp name!(value) when is_atom(value), do: name!(Atom.to_string(value))

  defp name!(value) do
    true =
      is_binary(value) and byte_size(value) <= 128 and
        Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, value)

    value
  end

  defp version!(value) do
    true =
      is_binary(value) and byte_size(value) <= 128 and
        Regex.match?(~r/\A[0-9][A-Za-z0-9.+-]*\z/, value)

    value
  end

  defp digest!(value) do
    true = is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
    value
  end

  defp path!(value) do
    true =
      is_binary(value) and String.valid?(value) and byte_size(value) <= 512 and
        not Regex.match?(~r/[\x00-\x1f\x7f\\]/, value) and
        length(String.split(value, "/")) <= 32 and
        Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."]))

    value
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp sha(bytes), do: hex(:crypto.hash(:sha256, bytes))
end

try do
  Frameshift.Release.CoreMaterialParser.run(System.argv())
rescue
  _ ->
    IO.puts(:stderr, "core dependency parser: input unavailable or outside admitted profile")
    System.halt(1)
catch
  _, _ ->
    IO.puts(:stderr, "core dependency parser: input unavailable or outside admitted profile")
    System.halt(1)
end
