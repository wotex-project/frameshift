defmodule Frameshift.Protocol.SchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Protocol.Schema

  @fixtures_dir Path.expand("../../../../../protocol/fixtures", __DIR__)

  test "every declared schema compiles without network resolution" do
    for name <- Schema.names() do
      assert {:ok, %JSV.Root{}} = Schema.compiled(name)
    end
  end

  test "conformance fixtures have the declared validity" do
    manifest = decode_fixture("conformance.json")

    for fixture <- manifest["cases"] do
      document = decode_fixture(fixture["document"])
      result = Schema.validate(fixture["schema"], document)

      if fixture["valid"] do
        assert :ok = result, "expected #{fixture["document"]} to be valid"
      else
        assert {:error, _} = result,
               "expected #{fixture["document"]} to be invalid"
      end
    end
  end

  test "unknown schemas are rejected without creating atoms" do
    assert {:error, :unknown_schema} = Schema.validate("not-a-schema", %{})
  end

  test "indexed4 requires explicit packing and palette/color identities but preserves unknown layouts" do
    capabilities = decode_fixture("valid/capabilities-paper-indexed4.json")
    [profile] = capabilities["storage"]["artifactProfiles"]

    for field <- ~w(packing paletteRevision colorProfileRevision) do
      changed =
        put_in(capabilities, ["storage", "artifactProfiles"], [Map.delete(profile, field)])

      assert {:error, _} = Schema.validate("capabilities", changed)
    end

    unknown =
      put_in(capabilities, ["storage", "artifactProfiles"], [
        Map.put(profile, "packing", "future-indexed-layout")
      ])

    assert :ok = Schema.validate("capabilities", unknown)

    assert {:error, :unsupported_profile} =
             Frameshift.RenderProfile.compile(%{"width" => 1200, "height" => 1600}, unknown)
  end

  defp decode_fixture(relative_path) do
    @fixtures_dir
    |> Path.join(relative_path)
    |> File.read!()
    |> JSON.decode!()
  end
end
