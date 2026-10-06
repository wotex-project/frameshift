defmodule FrameshiftRelease.SourceRecord do
  @moduledoc """
  Admits exact frozen source records under independently supplied identities.

  `parse/3` validates the existing schema-one `release-source-inputs` record
  against a stable tag and exact SHA-1 commit. It preserves producer field/file
  order, raw path spelling, Git blob identities, modes and SHA-256 byte facts.
  The record remains a declaration with publication authority `none`.

  ## Retained custody

  `with_record/6` additionally checks an independent SHA-256 of the original
  complete record, then runs a consumer inside `FrameshiftRelease.Input` custody.
  The record must be a current-owner unaliased 0600 file in an owned 0700 parent.
  The parent identity is checked again after consumption; file identity remains
  held through the worker's closing check and actual exit. Inputs are at most
  8 MiB. Optional `:worker` and `:budget_ms` select the qualified adapter and
  bounded whole callback job, defaulting to 60 seconds.

  ## Meaning and limits

  Obtain tag, commit and digest from an independent retained source. This module
  performs no Git/Mix command, source-file comparison, complete candidate
  namespace admission, dependency provenance, producer execution, signing or
  publication. A valid declaration does not establish a clean matching checkout
  or actual application version. The live collector/verifier must still join
  those requirements before source/receipt consumers switch.

  Fixed refusals contain no private paths or bytes. Consumer exceptions abort
  under the input owner's actual-exit rules and become a fixed source refusal;
  unknown worker custody remains explicit. No input or completed record is
  repaired, rewritten or promoted on failure.
  """

  import Bitwise, only: [band: 2]
  alias FrameshiftRelease.{Input, RecordJSON}
  @maximum 8 * 1024 * 1024
  @keys ~w(schemaVersion kind product tag version commit tree publicationAuthority toolchainInput dependencyLocks files)
  @file_keys ~w(path mode blob bytes sha256)
  @version ~r/\Av(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/

  @doc "Checks the exact existing producer schema against a stable tag and commit."
  @spec parse(binary(), String.t(), String.t()) :: {:ok, map()} | {:error, :source_refused}
  def parse(bytes, tag, commit) do
    ensure!(is_binary(tag) and byte_size(tag) <= 33 and Regex.match?(@version, tag))
    ensure!(hex?(commit, 40))
    {:ok, ordered} = RecordJSON.decode(bytes, @maximum)
    record = object!(ordered, @keys)
    ensure!(record["schemaVersion"] === 1 and record["kind"] == "release-source-inputs")
    ensure!(record["product"] == "io.frameshift.app" and record["publicationAuthority"] == "none")
    ensure!(record["tag"] == tag and record["version"] == String.slice(tag, 1..-1//1))
    ensure!(record["commit"] == commit and hex?(record["tree"], 40))
    ensure!(record["toolchainInput"] == ".mise.toml")
    ensure!(is_list(record["files"]) and length(record["files"]) in 1..65536)
    files = Enum.map(record["files"], &file!/1)
    paths = Enum.map(files, & &1["path"])
    ensure!(paths == Enum.sort(paths) and length(Enum.uniq(paths)) == length(paths))
    seen = MapSet.new(paths)
    Enum.each(paths, &parents!(&1, seen))

    ensure!(
      Enum.all?(
        [".mise.toml", "apps/core/mix.exs", "release/read-version.exs"],
        &MapSet.member?(seen, &1)
      )
    )

    locks =
      Enum.filter(
        paths,
        &(Path.basename(&1) in [
            "mix.lock",
            "Cargo.lock",
            "Package.resolved",
            "package-lock.json",
            "manifest.toml"
          ])
      )

    ensure!(record["dependencyLocks"] == locks)
    {:ok, Map.put(record, "files", files)}
  rescue
    _ -> {:error, :source_refused}
  catch
    _ -> {:error, :source_refused}
  end

  @doc "Consumes an independently pinned private record through actual closing custody."
  @spec with_record(String.t(), String.t(), String.t(), String.t(), (map() -> result), keyword()) ::
          {:ok, result} | {:error, atom()}
        when result: term()
  def with_record(path, digest, tag, commit, consumer, options \\ []) do
    ensure!(hex?(digest, 64) and is_function(consumer, 1))

    ensure!(
      Keyword.keyword?(options) and
        Enum.all?(Keyword.keys(options), &(&1 in [:worker, :budget_ms]))
    )

    ensure!(length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))))
    before = custody!(path)

    Input.with_input(
      path,
      Keyword.merge(options, maximum: @maximum, private_key: true),
      fn bytes ->
        ensure!(sha256(bytes) == digest)
        {:ok, record} = parse(bytes, tag, commit)
        result = consumer.(record)
        ensure!(custody!(path) == before)
        result
      end
    )
  rescue
    _ -> {:error, :source_refused}
  catch
    _ -> {:error, :source_refused}
  end

  defp file!(ordered) do
    file = object!(ordered, @file_keys)
    ensure!(path?(file["path"]) and file["mode"] in ["100644", "100755"])
    ensure!(hex?(file["blob"], 40) and hex?(file["sha256"], 64))
    ensure!(is_integer(file["bytes"]) and file["bytes"] in 0..9_007_199_254_740_991)
    file
  end

  defp path?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4096 and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, value) and
        Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."]))

  defp parents!(path, seen) do
    parent = Path.dirname(path)

    if parent != "." do
      ensure!(not MapSet.member?(seen, parent))
      parents!(parent, seen)
    end
  end

  defp object!({:object, pairs}, keys) do
    ensure!(Enum.map(pairs, &elem(&1, 0)) == keys)
    Map.new(pairs)
  end

  defp hex?(value, length),
    do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp custody!(path) do
    parent = File.lstat!(Path.dirname(path), time: :posix)
    file = File.lstat!(path, time: :posix)
    ensure!(parent.type == :directory and band(parent.mode, 0o7777) == 0o700)
    ensure!(file.type == :regular and file.links == 1 and band(file.mode, 0o7777) == 0o600)
    ensure!(parent.uid == file.uid)
    Map.take(parent, [:major_device, :minor_device, :inode, :mode, :uid, :gid])
  end

  defp ensure!(true), do: :ok
  defp ensure!(_), do: throw(:source_refused)
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
