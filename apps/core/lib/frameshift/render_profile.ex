defmodule Frameshift.RenderProfile do
  @moduledoc """
  Compiles advertised artifact capabilities into a deterministic raster job.

  `compile/3` inspects already admitted master metadata and frame capabilities,
  selects a supported artifact profile or checks the requested profile ID, and
  returns the job, artifact attributes and exact selected profile. Selection uses
  capability structure rather than vendor or model branches.

  ## Supported rendering

  The current path accepts uncompressed tightly packed RGB24 in sRGB and bounded
  source/target dimensions. It computes a centered crop, bilinear resize, white
  background and no dithering. Other structurally valid advertised profiles remain
  discoverable but refuse until their color/packing implementation exists.

  This pure compiler does not read artwork, render bytes, resolve credentials or
  queue delivery. `Frameshift.RenderPipeline` supplies verified master pixels to
  the isolated worker and binds its output to the recipe/cache. A compiled job
  therefore establishes supported software intent, not physical panel acceptance.
  """

  @renderer_revision "frameshift-raster-v0.1"
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
         job: %{
           source_width: master["width"],
           source_height: master["height"],
           crop_x: crop_x,
           crop_y: crop_y,
           crop_width: crop_width,
           crop_height: crop_height,
           target_width: profile["width"],
           target_height: profile["height"],
           background: {255, 255, 255},
           output_format: :rgb24,
           resize_filter: :bilinear,
           dither_mode: :none,
           palette: []
         },
         attributes: %{
           profile_id: profile["id"],
           renderer_revision: @renderer_revision,
           media_type: profile["mediaType"]
         },
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

    case :frameshift_decisions.select_rgb24_profile(
           Enum.map(profiles, &candidate/1),
           requested_profile_id || "",
           text(color["kind"]),
           color_spaces(color["colorSpaces"]),
           text(color["transferFunction"])
         ) do
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
