defmodule FrameshiftRelease.Manifest do
  @moduledoc """
  Parses and creates exact compact schema-one release manifests.

  `parse/1` admits at most 64 KiB of compact UTF-8 JSON with one trailing LF,
  preserves object key order through round-trip checking and rejects duplicates.
  It returns the validated manifest as maps with string keys. `encode/1` creates
  fixed field order from a validated semantic manifest. Signature verification
  must use the original bytes, independently of this creation encoder.

  ## Artifact identities

  The product is `io.frameshift.app`, version is stable three-part SemVer and
  target tuples remain Mac universal DMG, Ubuntu amd64/arm64 DEB and Nerves Pi 5
  arm64 firmware. Flat/versioned filenames and targets are unique. Each artifact
  binds a positive length at most 8 GiB, SHA-256 and canonical immutable HTTPS
  URL with the exact version suffix. Validation matches the pinned Node 26.9
  ASCII URL profile, including canonical IPv4/IPv6 and empty delimiters.

  ## Acceptance boundary

  This pure module performs no file/network I/O, signature verification, signing,
  publication, replay or installed acceptance. `FrameshiftRelease.Input` owns
  file custody and `FrameshiftRelease.Trust` owns independently pinned SPKI and
  whole-message authentication. Fixed errors do not contain private input.
  """

  @keys ["schemaVersion", "product", "version", "artifacts"]
  @artifact_keys ["platform", "architecture", "format", "file", "url", "bytes", "sha256"]
  @tuples [
    {"macos", "universal", "dmg"},
    {"ubuntu", "amd64", "deb"},
    {"ubuntu", "arm64", "deb"},
    {"nerves-rpi5", "arm64", "fw"}
  ]
  @version ~r/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/

  @doc "Returns validated string-keyed maps from original compact signed bytes."
  @spec parse(binary()) :: {:ok, map()} | {:error, :invalid_manifest}
  def parse(bytes) when is_binary(bytes) and byte_size(bytes) in 2..65536 do
    callbacks = %{
      object_start: fn _ -> {MapSet.new(), []} end,
      object_push: fn key, value, {seen, pairs} ->
        if MapSet.member?(seen, key), do: throw(:invalid_manifest)
        {MapSet.put(seen, key), [{key, value} | pairs]}
      end,
      object_finish: fn {_, pairs}, outer -> {{:object, Enum.reverse(pairs)}, outer} end,
      float: fn _ -> throw(:invalid_manifest) end
    }

    {ordered, _, _} = :json.decode(bytes, :ok, callbacks)
    ensure!(json(ordered) <> "\n" == bytes)
    manifest = object!(ordered, @keys)
    ensure!(manifest["schemaVersion"] === 1 and manifest["product"] == "io.frameshift.app")
    version = manifest["version"]
    ensure!(is_binary(version) and byte_size(version) <= 32 and Regex.match?(@version, version))
    artifacts = manifest["artifacts"]
    ensure!(is_list(artifacts) and length(artifacts) in 1..16)
    validated = Enum.map(artifacts, &artifact!(&1, version))
    ensure!(length(Enum.uniq_by(validated, & &1["file"])) == length(validated))
    ensure!(length(Enum.uniq_by(validated, &tuple/1)) == length(validated))
    {:ok, Map.put(manifest, "artifacts", validated)}
  rescue
    _ -> {:error, :invalid_manifest}
  catch
    _ -> {:error, :invalid_manifest}
  end

  def parse(_), do: {:error, :invalid_manifest}

  @doc "Creates canonical field order while preserving the supplied artifact order."
  @spec encode(map()) :: {:ok, binary()} | {:error, :invalid_manifest}
  def encode(manifest) do
    ensure!(is_map(manifest) and Enum.sort(Map.keys(manifest)) == Enum.sort(@keys))

    artifacts =
      Enum.map(Map.fetch!(manifest, "artifacts"), fn artifact ->
        ensure!(is_map(artifact) and Enum.sort(Map.keys(artifact)) == Enum.sort(@artifact_keys))
        {:object, Enum.map(@artifact_keys, &{&1, Map.fetch!(artifact, &1)})}
      end)

    fields = Map.put(manifest, "artifacts", artifacts)
    bytes = json({:object, Enum.map(@keys, &{&1, Map.fetch!(fields, &1)})}) <> "\n"
    with {:ok, _} <- parse(bytes), do: {:ok, bytes}
  rescue
    _ -> {:error, :invalid_manifest}
  catch
    _ -> {:error, :invalid_manifest}
  end

  defp json(value) do
    encoder = fn
      {:object, pairs}, recurse -> :json.encode_key_value_list(pairs, recurse)
      other, recurse -> :json.encode_value(other, recurse)
    end

    IO.iodata_to_binary(:json.encode(value, encoder))
  end

  defp object!({:object, pairs}, keys) do
    ensure!(Enum.sort(Enum.map(pairs, &elem(&1, 0))) == Enum.sort(keys))
    Map.new(pairs)
  end

  defp object!(_, _), do: throw(:invalid_manifest)

  defp artifact!(ordered, version) do
    artifact = object!(ordered, @artifact_keys)
    ensure!(tuple(artifact) in @tuples)
    file = artifact["file"]

    ensure!(
      is_binary(file) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, file) and
        not String.contains?(file, "..") and String.contains?(file, version) and
        String.ends_with?(file, "." <> artifact["format"])
    )

    ensure!(is_integer(artifact["bytes"]) and artifact["bytes"] in 1..(8 * 1024 * 1024 * 1024))

    ensure!(
      is_binary(artifact["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, artifact["sha256"])
    )

    ensure!(canonical_url?(artifact["url"], "/v#{version}/#{file}"))
    artifact
  end

  defp tuple(a), do: {a["platform"], a["architecture"], a["format"]}
  defp ensure!(true), do: :ok
  defp ensure!(_), do: throw(:invalid_manifest)

  defp canonical_url?(url, suffix) when is_binary(url) do
    with true <- Enum.all?(:binary.bin_to_list(url), &(&1 in 33..126)),
         false <- String.contains?(url, ["%", "\\"]),
         {:ok, no_fragment} <- empty_delimiter(url, "#"),
         {:ok, main} <- empty_delimiter(no_fragment, "?"),
         "https://" <> rest <- main,
         [authority, path] <- String.split(rest, "/", parts: 2),
         path = "/" <> path,
         true <- String.ends_with?(path, suffix),
         false <- Regex.match?(~r/(?:\A|\/)latest(?:\/|\z)/i, path),
         false <- String.contains?(path, ["\"", "<", ">", "^", "`", "{", "}"]),
         false <- Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])),
         true <- canonical_host?(authority) do
      true
    else
      _ -> false
    end
  end

  defp canonical_url?(_, _), do: false

  defp empty_delimiter(text, delimiter) do
    case String.split(text, delimiter, parts: 2) do
      [body] -> {:ok, body}
      [body, ""] -> {:ok, body}
      _ -> :error
    end
  end

  defp canonical_host?("[" <> rest) do
    with true <- String.ends_with?(rest, "]"),
         host = binary_part(rest, 0, byte_size(rest) - 1),
         true <- Regex.match?(~r/\A[0-9a-f:]+\z/, host),
         {:ok, address} when tuple_size(address) == 8 <-
           :inet.parse_address(String.to_charlist(host)) do
      ipv6(address) == host
    else
      _ -> false
    end
  end

  defp canonical_host?(host) do
    forbidden = ["#", "/", ":", "<", ">", "?", "@", "[", "]", "^", "|"]

    valid =
      host != "" and not Regex.match?(~r/[A-Z]/, host) and
        not String.contains?(host, forbidden) and
        (not String.contains?(host, "xn-") or byte_size(host) <= 16384)

    numeric_host =
      if String.ends_with?(host, "."), do: String.slice(host, 0, byte_size(host) - 1), else: host

    tail = numeric_host |> String.split(".") |> List.last()

    if Regex.match?(~r/\A(?:[0-9]+|0x[0-9a-f]*)\z/, tail) do
      parts = String.split(host, ".")

      valid and length(parts) == 4 and
        Enum.all?(parts, fn part ->
          Regex.match?(~r/\A(?:0|[1-9][0-9]{0,2})\z/, part) and String.to_integer(part) <= 255
        end)
    else
      valid
    end
  end

  defp ipv6(address) do
    groups = Tuple.to_list(address)

    {best_start, best_length, _, _} =
      groups
      |> Enum.with_index()
      |> Enum.reduce(
        {0, 0, 0, 0},
        fn {value, index}, {best, length, start, current} ->
          if value == 0 do
            start = if current == 0, do: index, else: start
            current = current + 1

            if current > length,
              do: {start, current, start, current},
              else: {best, length, start, current}
          else
            {best, length, 0, 0}
          end
        end
      )

    text = Enum.map(groups, &String.downcase(Integer.to_string(&1, 16)))

    if best_length >= 2 do
      Enum.join(Enum.take(text, best_start), ":") <>
        "::" <>
        Enum.join(Enum.drop(text, best_start + best_length), ":")
    else
      Enum.join(text, ":")
    end
  end
end
