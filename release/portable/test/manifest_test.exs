defmodule FrameshiftRelease.ManifestTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias FrameshiftRelease.{Input, Manifest, Trust, Verifier}

  setup_all do
    oracle = Path.expand("fixtures/manifest-oracle.mjs", __DIR__)

    corpus =
      case System.get_env("FRAMESHIFT_MANIFEST_ORACLE") do
        nil ->
          {bytes, 0} = System.cmd(oracle_node(), [oracle])
          :json.decode(bytes)

        path ->
          {:ok, bytes} = Input.read(path, maximum: 2 * 1024 * 1024, worker: worker())
          :json.decode(bytes)
      end

    %{corpus: corpus, oracle: oracle}
  end

  setup %{corpus: corpus} do
    root =
      Path.join(System.tmp_dir!(), "frameshift-manifest-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    files = %{
      manifest: Path.join(root, "manifest.json"),
      signature: Path.join(root, "manifest.sig"),
      public: Path.join(root, "release.pub.pem"),
      trust: Path.join(root, "trust.sha256")
    }

    File.write!(files.manifest, Base.decode64!(corpus["message"]))
    File.write!(files.signature, Base.decode64!(corpus["signature"]))
    File.write!(files.public, corpus["pem"])
    File.write!(files.trust, corpus["fingerprint"] <> "\n")
    File.write!(Path.join(root, "Frameshift-1.2.3.dmg"), Base.decode64!(corpus["archive"]))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, files: files}
  end

  test "all pinned Node wire schema and URL cases have exact semantic parity", %{corpus: corpus} do
    assert length(corpus["cases"]) > 300

    Enum.each(corpus["cases"], fn item ->
      result = Manifest.parse(Base.decode64!(item["message"]))
      assert match?({:ok, _}, result) == item["accepted"], item["label"]
    end)

    assert {:ok, base} = Manifest.parse(Base.decode64!(corpus["message"]))
    assert base == corpus["base"]
    assert {:ok, encoded} = Manifest.encode(base)
    assert encoded == Base.decode64!(corpus["message"])
  end

  test "exact original metadata and SPKI verify while wrong trust message and signature refuse",
       %{corpus: c} do
    bytes = Base.decode64!(c["message"])
    signature = Base.decode64!(c["signature"])
    assert :ok = Trust.verify(bytes, signature, c["pem"], c["fingerprint"])
    assert {:ok, %{fingerprint: pin, public: public, spki: der}} = Trust.public_key(c["pem"])
    assert pin == c["fingerprint"] and byte_size(public) == 32 and byte_size(der) == 44

    for {message, signed, fingerprint} <- [
          {bytes <> " ", signature, pin},
          {bytes, signature, String.duplicate("0", 64)},
          {bytes, binary_part(signature, 0, 63), pin},
          {bytes, signature, String.upcase(pin)}
        ] do
      assert {:error, :signature_refused} = Trust.verify(message, signed, c["pem"], fingerprint)
    end
  end

  test "Elixir signatures verify locally and in the explicit Node producer lane", %{
    oracle: oracle,
    root: root
  } do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    message = "exact complete metadata\0\n"
    signature = :crypto.sign(:eddsa, :none, message, [private, :ed25519])
    der = Base.decode16!("302A300506032B6570032100") <> public
    pem = "-----BEGIN PUBLIC KEY-----\n" <> Base.encode64(der) <> "\n-----END PUBLIC KEY-----\n"

    assert :ok =
             Trust.verify(
               message,
               signature,
               pem,
               Base.encode16(:crypto.hash(:sha256, der), case: :lower)
             )

    if System.get_env("FRAMESHIFT_MANIFEST_ORACLE") do
      # Node interoperability ran on the pinned Mac producer; Ubuntu repeats
      # native crypto verification without requiring a Node runtime.
      assert byte_size(signature) == 64
    else
      path = Path.join(root, "public-interop.json")

      File.write!(
        path,
        :json.encode(%{
          "pem" => pem,
          "message" => Base.encode64(message),
          "signature" => Base.encode64(signature)
        })
      )

      assert {"verified\n", 0} = System.cmd(oracle_node(), [oracle, "verify", path])
    end
  end

  test "public SPKI refuses private other multiple malformed and noncanonical PEM", %{corpus: c} do
    {:ok, key} = Trust.public_key(c["pem"])
    encoded = Base.encode64(key.spki)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    last = :binary.at(encoded, byte_size(encoded) - 2)
    {index, 1} = :binary.match(alphabet, <<last>>)

    noncanonical =
      binary_part(encoded, 0, byte_size(encoded) - 2) <>
        <<:binary.at(alphabet, index + 1)>> <> "="

    assert {:ok, key.spki} == Base.decode64(noncanonical, ignore: :whitespace)
    pem = fn body -> "-----BEGIN PUBLIC KEY-----\n" <> body <> "\n-----END PUBLIC KEY-----\n" end
    null_parameters = Base.decode16!("302C300706032B65700500032100") <> key.public

    for pem <- [
          String.replace(c["pem"], "PUBLIC KEY", "PRIVATE KEY"),
          c["pem"] <> c["pem"],
          "extra\n" <> c["pem"],
          String.replace(c["pem"], "PUBLIC KEY", "CERTIFICATE"),
          String.replace(c["pem"], "-----BEGIN", "-----begin"),
          pem.(noncanonical),
          pem.(Base.encode64(null_parameters)),
          pem.(Base.encode64(key.spki <> <<0>>)),
          <<255>>,
          String.duplicate("a", 16385)
        ] do
      assert {:error, :invalid_public_key} = Trust.public_key(pem)
    end

    assert {:ok, _} = Trust.public_key(String.replace(c["pem"], "\n", "\r\n"))
  end

  test "actual native read hash and independently pinned signature join exact local archives", %{
    corpus: c,
    files: f,
    root: root
  } do
    assert {:ok, manifest} =
             Verifier.verify_release(f.manifest, f.signature, f.public, root, f.trust,
               worker: worker()
             )

    assert manifest == c["base"]

    assert {:ok, ^manifest} =
             Verifier.verify_signature(f.manifest, f.signature, f.public, f.trust,
               worker: worker()
             )

    File.write!(Path.join(root, "Frameshift-1.2.3.dmg"), "changed local fixture installer")

    assert {:error, :artifact_refused} =
             Verifier.verify_release(f.manifest, f.signature, f.public, root, f.trust,
               worker: worker()
             )

    assert {:ok, ^manifest} =
             Verifier.verify_signature(f.manifest, f.signature, f.public, f.trust,
               worker: worker()
             )
  end

  test "trust grammar protection input aliases FIFOs and changed metadata refuse", %{
    corpus: c,
    files: f,
    root: root
  } do
    for fingerprint <- [
          String.upcase(c["fingerprint"]),
          c["fingerprint"] <> "\n\n",
          " " <> c["fingerprint"]
        ] do
      File.write!(f.trust, fingerprint)

      assert {:error, _} =
               Verifier.verify_signature(f.manifest, f.signature, f.public, f.trust,
                 worker: worker()
               )
    end

    File.write!(f.trust, c["fingerprint"])
    File.chmod!(f.trust, 0o666)

    assert {:error, :input_refused} =
             Verifier.verify_signature(f.manifest, f.signature, f.public, f.trust,
               worker: worker()
             )

    File.chmod!(f.trust, 0o600)

    for key <- [:manifest, :signature, :public, :trust] do
      path = Map.fetch!(f, key)
      alias_path = Path.join(root, "alias-#{key}")
      File.ln_s!(path, alias_path)
      aliased = Map.put(f, key, alias_path)

      assert {:error, :input_refused} =
               Verifier.verify_signature(
                 aliased.manifest,
                 aliased.signature,
                 aliased.public,
                 aliased.trust,
                 worker: worker()
               )

      fifo = Path.join(root, "fifo-#{key}")
      assert {_, 0} = System.cmd("mkfifo", [fifo])
      unsafe = Map.put(f, key, fifo)

      assert {:error, :input_refused} =
               Verifier.verify_signature(
                 unsafe.manifest,
                 unsafe.signature,
                 unsafe.public,
                 unsafe.trust,
                 worker: worker()
               )
    end

    File.write!(f.manifest, Base.decode64!(c["message"]) <> " ")

    assert {:error, :invalid_manifest} =
             Verifier.verify_signature(f.manifest, f.signature, f.public, f.trust,
               worker: worker()
             )
  end

  test "actual escript joins local artifacts and signature-only scope", %{files: f, root: root} do
    assert {"verified 1.2.3: 1 exact artifacts\n", 0} =
             cli(["verify", f.manifest, f.signature, f.public, root, f.trust])

    File.rm!(Path.join(root, "Frameshift-1.2.3.dmg"))

    assert {"verified signature 1.2.3: 1 declared artifacts\n", 0} =
             cli(["verify-signature", f.manifest, f.signature, f.public, f.trust])

    assert {"release verification refused: invalid input, trust or custody\n", 1} =
             cli(["verify", f.manifest, f.signature, f.public, root, f.trust])
  end

  test "actual escript refuses wrong trust FIFO and usage with fixed diagnostics", %{
    corpus: c,
    files: f,
    root: root
  } do
    assert {usage, 64} = cli([])
    assert String.starts_with?(usage, "usage: frameshift-release")
    File.write!(f.trust, String.duplicate("0", 64))
    args = ["verify-signature", f.manifest, f.signature, f.public, f.trust]
    assert {"release verification refused: invalid input, trust or custody\n", 1} = cli(args)
    File.write!(f.trust, c["fingerprint"])
    File.rm!(f.manifest)
    assert {_, 0} = System.cmd("mkfifo", [f.manifest])
    assert {"release verification refused: invalid input, trust or custody\n", 1} = cli(args)
    assert not String.contains?(usage, root)
  end

  defp cli(arguments) do
    executable = System.get_env("FRAMESHIFT_ESCRIPT") || pinned_tool("escript")
    script = Path.expand("../frameshift-release", __DIR__)
    System.cmd(executable, [script, "--worker", worker() | arguments], stderr_to_stdout: true)
  end

  defp worker,
    do:
      System.get_env("FRAMESHIFT_RELEASE_INPUT_WORKER") ||
        Path.expand("../worker/zig-out/bin/frameshift-release-input", __DIR__)

  defp oracle_node do
    System.get_env("FRAMESHIFT_NODE") || pinned_tool("node")
  end

  defp pinned_tool(tool) do
    case System.cmd("mise", ["which", tool]) do
      {path, 0} -> String.trim(path)
      _ -> raise "Pinned test tool is unavailable"
    end
  end
end
