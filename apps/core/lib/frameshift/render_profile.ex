defmodule Frameshift.RenderProfile do
  @moduledoc """
  Compiles advertised artifact capabilities into a deterministic raster job.

  `compile/3` inspects already admitted master metadata and frame capabilities,
  selects a supported artifact profile or checks the requested profile ID, and
  returns the job, artifact attributes and exact selected profile. Selection uses
  capability structure rather than vendor or model branches.

  ## Supported rendering

  The compiler accepts uncompressed tightly packed RGB24 in sRGB, or the closed
  `indexed4-msb-row-major-v1` restricted-palette layout. Both use centered crop,
  bilinear resize, white alpha background and no dithering. Indexed4 requires
  even native rows, explicit ordered RGB/hardware-code pairs, palette/color
  revisions, identity orientation, square pixels and zero safe insets. Its final
  mapping/packing runs inside `Frameshift.Renderer`, not an unpinned host stage.
  Unsupported advertised color, geometry and layouts remain discoverable and
  return `:unsupported_profile`; vendor/model names never select a profile.

  ## Recipes and qualification

  The returned attributes include the byte-producing algorithm revision and,
  for indexed4, the exact packing/palette/color revisions. Callers must preserve
  them alongside the ordered palette and wire codes in the immutable recipe.
  RGB24 retains its existing algorithm; indexed4 uses a distinct FSR1 0.2 binding
  and cannot borrow an older RGB qualification. Preview may reuse this job's crop
  and palette with a bounded indexed8 output before expanding RGB approximation.

  This pure compiler does not read artwork, render bytes, resolve credentials or
  queue delivery. `Frameshift.RenderPipeline` supplies verified master pixels to
  the isolated worker and binds its output to the recipe/cache. A compiled job
  therefore establishes supported software intent, not physical panel acceptance.
  """

  @renderer_revision "frameshift-raster-v0.1"
  @indexed4_revision "frameshift-raster-indexed4-v0.2"
  @maximum_pixels 16_777_216

  @type compilation :: %{
          job: map(),
          attributes: map(),
          profile: map()
        }

  @doc "Selects a compatible advertised profile and compiles a centered raster job."
  @spec compile(map(), map(), String.t() | nil) :: {:ok, compilation()} | {:error, atom()}
  def compile(master, capabilities, requested_profile_id \\ nil)

  def compile(master, capabilities, requested_profile_id)
      when is_map(master) and is_map(capabilities) do
    with {:ok, profiles} <- artifact_profiles(capabilities),
         {:ok, profile} <- select_profile(profiles, capabilities, requested_profile_id),
         :ok <- validate_source(master),
         :ok <- validate_target(profile),
         {crop_x, crop_y, crop_width, crop_height} <- center_crop(master, profile) do
      {:ok,
       %{
         job:
           %{
             source_width: master["width"],
             source_height: master["height"],
             crop_x: crop_x,
             crop_y: crop_y,
             crop_width: crop_width,
             crop_height: crop_height,
             target_width: profile["width"],
             target_height: profile["height"],
             background: {255, 255, 255},
             resize_filter: :bilinear,
             dither_mode: :none
           }
           |> Map.merge(job_options(capabilities)),
         attributes: attributes(profile, capabilities),
         profile: profile
       }}
    end
  end

  def compile(_, _, _),
    do: {:error, :invalid_render_profile}

  defp artifact_profiles(%{"storage" => %{"artifactProfiles" => profiles}})
       when is_list(profiles) and profiles != [],
       do: {:ok, profiles}

  defp artifact_profiles(_), do: {:error, :artifact_profiles_missing}

  defp select_profile(profiles, capabilities, requested_profile_id)
       when is_binary(requested_profile_id) or is_nil(requested_profile_id) do
    color = color_contract(capabilities)

    case select_supported_id(profiles, color, capabilities, requested_profile_id || "") do
      {:ok, id} ->
        case Enum.find(profiles, &(is_map(&1) and &1["id"] == id)) do
          nil -> {:error, :unsupported_profile}
          profile -> {:ok, profile}
        end

      {:error, :unsupported_profile} ->
        {:error, :unsupported_profile}
    end
  end

  defp select_profile(_, _, _),
    do: {:error, :unsupported_profile}

  defp select_supported_id(
         profiles,
         %{"kind" => "restricted-palette"} = color,
         capabilities,
         requested
       ) do
    :frameshift_decisions.select_indexed4_profile(
      Enum.map(profiles, &indexed4_candidate(&1, capabilities)),
      requested,
      text(color["kind"]),
      text(color["profileRevision"]),
      palette_entries(color["palette"])
    )
  end

  defp select_supported_id(profiles, color, _, requested) do
    :frameshift_decisions.select_rgb24_profile(
      Enum.map(profiles, &candidate/1),
      requested,
      text(color["kind"]),
      color_spaces(color["colorSpaces"]),
      text(color["transferFunction"])
    )
  end

  defp color_contract(%{"color" => %{} = color}), do: color
  defp color_contract(_), do: %{}

  defp color_spaces(spaces) when is_list(spaces), do: Enum.filter(spaces, &is_binary/1)
  defp color_spaces(_), do: []

  defp candidate(%{} = profile) do
    {:raster_candidate, text(profile["id"]), integer(profile["width"]),
     integer(profile["height"]), integer(profile["maximumAssetBytes"]),
     text(profile["channelOrder"]), integer(profile["bitDepth"]), text(profile["compression"]),
     integer(profile["rowAlignment"]), text(profile["byteOrder"])}
  end

  defp candidate(_), do: {:raster_candidate, "", 0, 0, 0, "", 0, "", 0, ""}

  defp indexed4_candidate(%{} = profile, capabilities) do
    packing = if native_geometry?(capabilities, profile), do: text(profile["packing"]), else: ""

    {:indexed4_candidate, candidate(profile), packing, text(profile["paletteRevision"]),
     text(profile["colorProfileRevision"])}
  end

  defp indexed4_candidate(_, _),
    do: {:indexed4_candidate, candidate(nil), "", "", ""}

  defp native_geometry?(%{"geometry" => geometry}, profile) when is_map(geometry) do
    geometry["width"] == profile["width"] and geometry["height"] == profile["height"] and
      geometry["orientation"] == "identity" and
      geometry["pixelAspectRatio"] == %{"horizontal" => 1, "vertical" => 1} and
      geometry["safeInset"] == %{"top" => 0, "right" => 0, "bottom" => 0, "left" => 0}
  end

  defp native_geometry?(_, _), do: false

  defp palette_entries(entries) when is_list(entries), do: Enum.map(entries, &palette_entry/1)
  defp palette_entries(_), do: []

  defp palette_entry(%{"wireCode" => code, "previewSrgb" => [red, green, blue]}) do
    {:palette_entry, palette_integer(code), palette_integer(red), palette_integer(green),
     palette_integer(blue)}
  end

  defp palette_entry(_), do: {:palette_entry, -1, -1, -1, -1}
  defp palette_integer(value) when is_integer(value), do: value
  defp palette_integer(_), do: -1

  defp job_options(%{"color" => %{"kind" => "restricted-palette", "palette" => palette}}) do
    %{
      output_format: :indexed4_msb,
      palette: Enum.map(palette, &List.to_tuple(&1["previewSrgb"])),
      wire_codes: Enum.map(palette, & &1["wireCode"])
    }
  end

  defp job_options(_), do: %{output_format: :rgb24, palette: []}

  defp attributes(profile, %{"color" => %{"kind" => "restricted-palette"}}) do
    %{
      profile_id: profile["id"],
      renderer_revision: @indexed4_revision,
      media_type: profile["mediaType"],
      packing: profile["packing"],
      palette_revision: profile["paletteRevision"],
      color_profile_revision: profile["colorProfileRevision"]
    }
  end

  defp attributes(profile, _) do
    %{
      profile_id: profile["id"],
      renderer_revision: @renderer_revision,
      media_type: profile["mediaType"]
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0

  defp validate_source(%{"width" => width, "height" => height})
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 and
              width * height <= @maximum_pixels,
       do: :ok

  defp validate_source(_), do: {:error, :invalid_source_dimensions}

  defp validate_target(%{"width" => width, "height" => height})
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 and
              width * height <= @maximum_pixels,
       do: :ok

  defp validate_target(_), do: {:error, :invalid_target_dimensions}

  defp center_crop(master, profile) do
    source_width = master["width"]
    source_height = master["height"]
    target_width = profile["width"]
    target_height = profile["height"]

    if source_width * target_height > source_height * target_width do
      crop_width = max(1, div(source_height * target_width, target_height))
      {div(source_width - crop_width, 2), 0, crop_width, source_height}
    else
      crop_height = max(1, div(source_width * target_height, target_width))
      {0, div(source_height - crop_height, 2), source_width, crop_height}
    end
  end
end
