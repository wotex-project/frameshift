defmodule Frameshift.Import.IntentTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Import.Intent

  test "exact intent hashes all caller fields, independently of a codec context" do
    intent = intent()
    assert :ok = Intent.validate(intent)
    assert {:ok, hash} = Intent.identity(intent)
    assert hash == Digest.sha256(RFC8785.encode!(intent))

    for key <- ~w(id title originalFilename sourceDigest) do
      changed = if key == "sourceDigest", do: Digest.sha256("other"), else: "changed"
      assert {:ok, next} = Intent.identity(Map.put(intent, key, changed))
      refute next == hash
    end
  end

  test "caller geometry, source path, codec, actor, missing and excessive fields refuse" do
    for key <- ~w(width importPath codecDigest actor),
        do:
          assert(
            {:error, :invalid_import_intent} == Intent.validate(Map.put(intent(), key, "forged"))
          )

    for key <- Map.keys(intent()),
        do: assert({:error, :invalid_import_intent} == Intent.validate(Map.delete(intent(), key)))

    for count <- [0, -1, 134_217_729, 1.0],
        do:
          assert(
            {:error, :invalid_import_intent} ==
              Intent.validate(%{intent() | "sourceByteCount" => count})
          )

    assert :ok = Intent.validate(%{intent() | "sourceByteCount" => 134_217_728})
  end

  test "text is bounded NFC UTF-8 with no controls or service paths" do
    for {key, value} <- [
          {"id", ""},
          {"id", <<255>>},
          {"id", String.duplicate("x", 65)},
          {"title", " "},
          {"title", "e\u0301"},
          {"title", "x\n"},
          {"title", String.duplicate("x", 257)},
          {"originalFilename", "a/b"},
          {"originalFilename", <<0>>},
          {"originalFilename", "a\u0085b"},
          {"originalFilename", String.duplicate("x", 256)},
          {"sourceDigest", "sha256:bad"}
        ] do
      assert {:error, :invalid_import_intent} = Intent.validate(Map.put(intent(), key, value))
    end

    assert :ok = Intent.validate(%{intent() | "title" => "Été", "originalFilename" => "été.png"})
    assert {:error, :invalid_import_intent} = Intent.identity(nil)
  end

  defp intent do
    %{
      "kind" => "importOriginal",
      "id" => "source-1",
      "title" => "Artwork",
      "originalFilename" => "original.png",
      "sourceByteCount" => 1,
      "sourceDigest" => Digest.sha256("V")
    }
  end
end
