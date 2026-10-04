defmodule Frameshift.RenderPreview do
  @moduledoc """
  Produces bounded local previews from verified immutable master pixels.

  `render/4` reads an active master through `Frameshift.Library`, verifies its
  versioned package and dimensions, then renders with the isolated Zig worker.
  A source preview keeps the full source crop. A target preview checks the exact
  paired capability digest and currently selected profile before reusing
  `Frameshift.RenderProfile`'s crop, alpha background and resize contract.

  ## Bounds and identity

  Each output dimension is at most 256 pixels and the worker deadline is five
  seconds. Smaller rasters are not enlarged. The response retains original aspect
  dimensions, master/target/profile/capability identities, worker build digest and
  the digest of the exact RGB24 pixels. Native clients must verify these fields
  and the bounded byte count before displaying an image.

  Previews are transient approximations: they do not register recipes/artifacts,
  queue delivery, qualify a binding or establish physically displayed artwork.
  Unsupported profiles, changed selection, missing/removed masters, corrupt
  packages, worker loss and busy/deadline failures refuse with finite errors.
  Caller paths, pixels and replacement capability maps are never accepted.
  """

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.MasterPackage
  alias Frameshift.Renderer
  alias Frameshift.RenderProfile

  @maximum_edge 256
  @deadline_ms 5_000

  @doc "Renders a source preview or one exact selected target/profile snapshot without mutation."
  @spec render(GenServer.server(), GenServer.server(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, atom()}
  def render(library, renderer, master_digest, target \\ nil) do
    with true <- Digest.valid_sha256?(master_digest),
         {:ok, %{"removed_at_ms" => nil} = master} <- Library.get_master(library, master_digest),
         {:ok, job, identity} <- preview_job(library, master, target),
         {:ok, %{"bytes" => bytes}} <-
           Library.read_object(library, master_digest, MasterPackage.maximum_package_bytes()),
         {:ok, decoded} <- MasterPackage.decode(bytes),
         true <- decoded.width == master["width"] and decoded.height == master["height"],
         build_digest <- Renderer.build_digest(renderer),
         {:ok, rendered} <-
           Renderer.render_qualified(renderer, Map.put(job, :rgba, decoded.rgba), build_digest,
             deadline_ms: @deadline_ms
           ) do
      {:ok,
       Map.merge(identity, %{
         "masterDigest" => master_digest,
         "approximation" => true,
         "format" => "rgb24",
         "width" => rendered.width,
         "height" => rendered.height,
         "rgb" => Base.encode64(rendered.bytes),
         "digest" => Digest.sha256(rendered.bytes),
         "rendererBuildDigest" => build_digest
       })}
    else
      :not_found -> {:error, :item_not_found}
      false -> {:error, :invalid_preview}
      {:ok, _} -> {:error, :item_not_found}
      {:error, reason} -> {:error, preview_error(reason)}
    end
  catch
    :exit, _ -> {:error, :preview_unavailable}
  end

  defp preview_job(_, master, nil) do
    {width, height} = preview_dimensions(master["width"], master["height"])

    job = %{
      source_width: master["width"],
      source_height: master["height"],
      crop_x: 0,
      crop_y: 0,
      crop_width: master["width"],
      crop_height: master["height"],
      target_width: width,
      target_height: height,
      background: {255, 255, 255},
      output_format: :rgb24,
      resize_filter: :bilinear,
      dither_mode: :none,
      palette: []
    }

    {:ok, job,
     %{
       "kind" => "source",
       "targetID" => nil,
       "profileID" => nil,
       "capabilityDigest" => nil,
       "aspectWidth" => master["width"],
       "aspectHeight" => master["height"]
     }}
  end

  defp preview_job(library, master, %{
         "targetID" => target_id,
         "profileID" => profile_id,
         "capabilityDigest" => digest
       }) do
    with {:ok, frame} <- Library.get_paired_frame(library, target_id),
         true <- digest == Digest.sha256(RFC8785.encode!(frame["capabilities"])),
         {:ok, compilation} <-
           RenderProfile.compile(master, frame["capabilities"], selected_profile(library, frame)),
         true <- compilation.profile["id"] == profile_id do
      job = compilation.job
      {width, height} = preview_dimensions(job.target_width, job.target_height)

      {:ok, %{job | target_width: width, target_height: height},
       %{
         "kind" => "target",
         "targetID" => target_id,
         "profileID" => profile_id,
         "capabilityDigest" => digest,
         "aspectWidth" => job.target_width,
         "aspectHeight" => job.target_height
       }}
    else
      :not_found -> {:error, :target_not_found}
      false -> {:error, :preview_profile_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preview_job(_, _, _), do: {:error, :invalid_preview}

  defp selected_profile(library, frame) do
    case Library.active_qualification(library, frame["frame_id"]) do
      {:ok, binding} -> binding["manifest"]["profileId"]
      :not_found -> nil
    end
  end

  defp preview_dimensions(width, height) do
    longest = max(width, height)

    if longest <= @maximum_edge,
      do: {width, height},
      else:
        {max(1, div(width * @maximum_edge, longest)),
         max(1, div(height * @maximum_edge, longest))}
  end

  defp preview_error(reason)
       when reason in [
              :busy,
              :timeout,
              :unsupported_profile,
              :preview_profile_changed,
              :target_not_found
            ],
       do: reason

  defp preview_error(_), do: :preview_unavailable
end
