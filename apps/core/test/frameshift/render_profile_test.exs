defmodule Frameshift.RenderProfileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.RenderProfile

  test "selects a structurally compatible profile and creates a centered crop" do
    master = %{"width" => 4, "height" => 4}
    capabilities = capabilities([rgb_profile("urn:frameshift:profile:photo-rgb24-v1", 2, 1)])

    assert {:ok, compilation} = RenderProfile.compile(master, capabilities)
    assert compilation.profile["id"] == "urn:frameshift:profile:photo-rgb24-v1"
    assert compilation.job.crop_x == 0
    assert compilation.job.crop_y == 1
    assert compilation.job.crop_width == 4
    assert compilation.job.crop_height == 2
    assert compilation.job.output_format == :rgb24
    assert compilation.attributes.media_type == "application/vnd.vendor.panel-rgb24"
  end

  test "selection depends on advertised structure rather than vendor naming" do
    unsupported =
      rgb_profile("urn:vendor:any-name", 2, 2)
      |> Map.put("compression", "zstd")

    compatible = rgb_profile("urn:another-vendor:opaque-profile", 2, 2)
    capabilities = capabilities([unsupported, compatible])

    assert {:ok, %{profile: ^compatible}} =
             RenderProfile.compile(%{"width" => 2, "height" => 2}, capabilities)

    assert {:error, :unsupported_profile} =
             RenderProfile.compile(
               %{"width" => 2, "height" => 2},
               capabilities,
               "urn:vendor:any-name"
             )
  end

  test "selection is order-independent and refuses duplicate profile identities" do
    later = rgb_profile("z-photo", 2, 2)
    first = rgb_profile("a-photo", 2, 2)
    master = %{"width" => 2, "height" => 2}

    assert {:ok, %{profile: ^first}} =
             RenderProfile.compile(master, capabilities([later, first]))

    assert {:error, :unsupported_profile} =
             RenderProfile.compile(master, capabilities([first, first]))
  end

  test "capacity and color are admitted before a render job exists" do
    master = %{"width" => 2, "height" => 2}
    too_small = Map.put(rgb_profile("rgb", 2, 2), "maximumAssetBytes", 11)

    assert {:error, :unsupported_profile} =
             RenderProfile.compile(master, capabilities([too_small]))

    capabilities =
      put_in(capabilities([rgb_profile("rgb", 2, 2)]), ["color", "colorSpaces"], ["p3"])

    assert {:error, :unsupported_profile} = RenderProfile.compile(master, capabilities)
  end

  test "indexed4 selects by structure and freezes explicit noncontiguous codes" do
    capabilities = indexed_capabilities()
    master = %{"width" => 6, "height" => 1}
    assert {:ok, c} = RenderProfile.compile(master, capabilities)
    assert c.job.output_format == :indexed4_msb
    assert c.job.wire_codes == [5, 6]
    assert c.job.palette == [{0, 0, 255}, {0, 255, 0}]
    assert c.attributes.packing == "indexed4-msb-row-major-v1"
    assert c.attributes.renderer_revision == "frameshift-raster-indexed4-v0.2"
    assert c.attributes.palette_revision == "synthetic-palette-v1"
  end

  test "indexed4 refuses unsupported packing, color, native geometry and code ambiguity" do
    master = %{"width" => 6, "height" => 1}
    original = indexed_capabilities()
    [profile] = original["storage"]["artifactProfiles"]

    for invalid <- [
          Map.put(profile, "packing", "indexed4-lsb"),
          Map.delete(profile, "packing"),
          Map.delete(profile, "paletteRevision"),
          Map.put(profile, "colorProfileRevision", "stale"),
          Map.put(profile, "maximumAssetBytes", 2),
          Map.put(profile, "width", 5),
          Map.put(profile, "rowAlignment", 4),
          Map.put(profile, "byteOrder", "big-endian"),
          Map.put(profile, "compression", "zstd")
        ] do
      cap = put_in(original, ["storage", "artifactProfiles"], [invalid])
      assert {:error, :unsupported_profile} = RenderProfile.compile(master, cap)
    end

    for {field, invalid} <- [
          {"orientation", "rotate-90"},
          {"width", 12},
          {"safeInset", %{"top" => 1, "right" => 0, "bottom" => 0, "left" => 0}},
          {"pixelAspectRatio", %{"horizontal" => 2, "vertical" => 1}}
        ] do
      assert {:error, :unsupported_profile} =
               RenderProfile.compile(master, put_in(original, ["geometry", field], invalid))
    end

    for entries <- [
          [],
          [%{"wireCode" => 0, "previewSrgb" => [0, 0, 0]}],
          [
            %{"wireCode" => 5, "previewSrgb" => [0, 0, 255]},
            %{"wireCode" => 5, "previewSrgb" => [0, 255, 0]}
          ],
          [
            %{"wireCode" => 16, "previewSrgb" => [0, 0, 255]},
            %{"wireCode" => 6, "previewSrgb" => [0, 255, 0]}
          ],
          [
            %{"wireCode" => 5, "previewSrgb" => [0, 0, 256]},
            %{"wireCode" => 6, "previewSrgb" => [0, 255, 0]}
          ],
          [nil, nil]
        ] do
      assert {:error, :unsupported_profile} =
               RenderProfile.compile(master, put_in(original, ["color", "palette"], entries))
    end

    assert {:error, :unsupported_profile} =
             RenderProfile.compile(
               master,
               put_in(original, ["storage", "artifactProfiles"], [profile, profile])
             )
  end

  defp indexed_capabilities do
    %{
      "geometry" => %{
        "width" => 6,
        "height" => 1,
        "orientation" => "identity",
        "safeInset" => %{"top" => 0, "right" => 0, "bottom" => 0, "left" => 0},
        "pixelAspectRatio" => %{"horizontal" => 1, "vertical" => 1}
      },
      "color" => %{
        "kind" => "restricted-palette",
        "profileRevision" => "synthetic-color-v1",
        "palette" => [
          %{"wireCode" => 5, "previewSrgb" => [0, 0, 255]},
          %{"wireCode" => 6, "previewSrgb" => [0, 255, 0]}
        ]
      },
      "storage" => %{
        "artifactProfiles" => [
          %{
            "id" => "urn:unrelated-vendor:opaque",
            "mediaType" => "application/vnd.vendor.indexed4",
            "width" => 6,
            "height" => 1,
            "maximumAssetBytes" => 3,
            "rowAlignment" => 1,
            "byteOrder" => "not-applicable",
            "compression" => "none",
            "channelOrder" => "palette-index",
            "bitDepth" => 4,
            "packing" => "indexed4-msb-row-major-v1",
            "paletteRevision" => "synthetic-palette-v1",
            "colorProfileRevision" => "synthetic-color-v1"
          }
        ]
      }
    }
  end

  defp capabilities(profiles) do
    %{
      "color" => %{
        "kind" => "continuous",
        "colorSpaces" => ["srgb"],
        "transferFunction" => "srgb"
      },
      "storage" => %{"artifactProfiles" => profiles}
    }
  end

  defp rgb_profile(id, width, height) do
    %{
      "id" => id,
      "mediaType" => "application/vnd.vendor.panel-rgb24",
      "width" => width,
      "height" => height,
      "maximumAssetBytes" => width * height * 3,
      "rowAlignment" => 1,
      "byteOrder" => "not-applicable",
      "channelOrder" => "rgb",
      "bitDepth" => 8,
      "compression" => "none"
    }
  end
end
