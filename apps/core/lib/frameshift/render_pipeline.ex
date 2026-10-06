defmodule Frameshift.RenderPipeline do
  @moduledoc """
  Renders verified stored masters and records exact immutable target artifacts.

  `render_stored_master/5` reads a registered master through
  `Frameshift.Library`, decodes its verified `Frameshift.MasterPackage`, validates
  the job and registers a canonical composition recipe. It checks the exact cache
  identity before invoking `Frameshift.Renderer` and stores the resulting bytes
  with profile and renderer revision metadata.

  Indexed4 recipes additionally freeze ordered hardware codes and the packing,
  palette and color revisions. The Zig executable produces final packed bytes;
  neither palette positions nor preview RGB bytes become the artifact digest.
  Missing or inconsistent indexed4 attributes refuse before recipe registration.

  ## Qualified work

  `render_qualified_stored_master/7` additionally checks the active frame/profile/
  transfer binding, executable build identity and supported software contract.
  Accepted work freezes those inputs before its immutable result is recorded;
  a later active-pointer change cannot rewrite earlier work or cached bytes.

  The renderer receives only canonical RGBA8 extracted from the durable package.
  Caller-provided replacement pixels, mismatched dimensions or stale qualification
  refuse. Platform source decoding remains outside this module. Successful rendering
  means exact artifact custody, not transport completion or physical display;
  delivery owners perform those later steps and preserve uncertain outcomes.
  """

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.MasterPackage
  alias Frameshift.Qualification.Contract
  alias Frameshift.Renderer
  alias Frameshift.Renderer.Protocol, as: RendererProtocol
  alias Frameshift.RenderProfile

  @required_attributes ~w(profile_id renderer_revision media_type)a

  @doc "Verifies a stored master, renders it, and registers its exact target artifact."
  @spec render_stored_master(
          GenServer.server(),
          GenServer.server(),
          String.t(),
          map(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  def render_stored_master(library, renderer, master_digest, job, attributes) do
    measure_render(fn ->
      do_render_stored_master(library, renderer, master_digest, job, attributes, nil, nil)
    end)
  end

  @doc "Accepts and renders work against one active frame/profile/transfer qualification."
  @spec render_qualified_stored_master(
          GenServer.server(),
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          map(),
          map()
        ) :: {:ok, map()} | {:error, term()}
  def render_qualified_stored_master(
        library,
        renderer,
        frame_id,
        mode,
        master_digest,
        job,
        attributes
      ) do
    measure_render(fn ->
      with {:ok, binding} <- active_binding(library, frame_id),
           :ok <- validate_binding(library, renderer, binding, frame_id, mode, job, attributes) do
        do_render_stored_master(
          library,
          renderer,
          master_digest,
          job,
          attributes,
          binding,
          frame_id
        )
      end
    end)
  end

  defp measure_render(operation) do
    started = System.monotonic_time(:millisecond)
    result = operation.()

    outcome =
      case result do
        {:ok, %{cache: :hit}} -> :cache_hit
        {:ok, _} -> :succeeded
        {:error, _} -> :failed
      end

    :telemetry.execute(
      [:frameshift, :render, :completed],
      %{duration_ms: System.monotonic_time(:millisecond) - started},
      %{outcome: outcome}
    )

    result
  end

  defp do_render_stored_master(
         library,
         renderer,
         master_digest,
         job,
         attributes,
         binding,
         frame_id
       ) do
    with :ok <- validate_attributes(attributes),
         :ok <- validate_wire_attributes(job, attributes),
         :ok <- validate_master_digest(master_digest),
         {:ok, master} <- Library.get_master(library, master_digest),
         :ok <- validate_master(master, job),
         {:ok, %{"bytes" => package}} <-
           Library.read_object(library, master_digest, MasterPackage.maximum_package_bytes()),
         {:ok, decoded} <- MasterPackage.decode(package),
         :ok <- validate_decoded(decoded, job),
         render_job = Map.put(job, :rgba, decoded.rgba),
         {:ok, _} <- RendererProtocol.encode_request(render_job),
         {:ok, recipe_hash} <-
           register_recipe(library, master_digest, render_job, attributes, binding) do
      produce_artifact(
        library,
        renderer,
        master_digest,
        recipe_hash,
        render_job,
        attributes,
        binding,
        frame_id
      )
    else
      :not_found -> {:error, :master_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_binding(library, frame_id) do
    case Library.active_qualification(library, frame_id) do
      {:ok, %{"status" => "admitted"} = binding} -> {:ok, binding}
      _ -> {:error, :qualification_not_active}
    end
  end

  defp validate_binding(library, renderer, binding, frame_id, mode, job, attributes) do
    manifest = binding["manifest"]

    with :ok <- Contract.validate(manifest),
         {:ok, frame} <- Library.get_paired_frame(library, frame_id),
         %{} = profile <-
           Enum.find(
             frame["capabilities"]["storage"]["artifactProfiles"],
             &(&1["id"] == manifest["profileId"])
           ),
         true <- binding["frame_id"] == frame_id,
         true <- manifest["transferMode"] == mode,
         true <- manifest["profileId"] == attributes.profile_id,
         true <- manifest["rendererAlgorithmRevision"] == attributes.renderer_revision,
         true <- profile["mediaType"] == attributes.media_type,
         true <- Renderer.build_digest(renderer) == manifest["rendererBuildDigest"],
         :ok <- validate_bound_job(job, attributes, frame["capabilities"]) do
      :ok
    else
      _ -> {:error, :qualification_runtime_mismatch}
    end
  end

  defp validate_bound_job(job, attributes, capabilities) do
    master = %{"width" => Map.get(job, :source_width), "height" => Map.get(job, :source_height)}

    with {:ok, compiled} <- RenderProfile.compile(master, capabilities, attributes.profile_id),
         true <- Enum.all?(compiled.attributes, fn {key, value} -> attributes[key] == value end),
         true <-
           Enum.all?(
             [:output_format, :target_width, :target_height, :palette, :wire_codes],
             fn key ->
               Map.get(job, key) == Map.get(compiled.job, key)
             end
           ) do
      :ok
    else
      _ -> {:error, :qualification_runtime_mismatch}
    end
  end

  defp validate_attributes(attributes) when is_map(attributes) do
    missing = Enum.reject(@required_attributes, &Map.has_key?(attributes, &1))

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      not Enum.all?(@required_attributes, &(is_binary(attributes[&1]) and attributes[&1] != "")) ->
        {:error, :invalid_attributes}

      true ->
        :ok
    end
  end

  defp validate_attributes(_), do: {:error, :invalid_attributes}

  defp validate_wire_attributes(%{output_format: :indexed4_msb}, attributes) do
    if attributes[:packing] == "indexed4-msb-row-major-v1" and
         attributes.renderer_revision == "frameshift-raster-indexed4-v0.2" and
         Enum.all?([:palette_revision, :color_profile_revision], fn key ->
           is_binary(attributes[key]) and byte_size(attributes[key]) in 1..128 and
             String.valid?(attributes[key])
         end),
       do: :ok,
       else: {:error, :invalid_attributes}
  end

  defp validate_wire_attributes(_, _), do: :ok

  defp validate_master_digest(digest) do
    if Digest.valid_sha256?(digest), do: :ok, else: {:error, :invalid_master_digest}
  end

  defp validate_master(master, job) do
    cond do
      master["media_type"] != MasterPackage.media_type() ->
        {:error, :unsupported_source_representation}

      master["width"] != job.source_width or master["height"] != job.source_height ->
        {:error, :source_dimensions_mismatch}

      true ->
        :ok
    end
  end

  defp validate_decoded(decoded, job) do
    if decoded.width == job.source_width and decoded.height == job.source_height,
      do: :ok,
      else: {:error, :source_dimensions_mismatch}
  end

  defp register_recipe(library, master_digest, job, attributes, binding) do
    parameters = %{
      "background" => Tuple.to_list(job.background),
      "crop" => %{
        "height" => job.crop_height,
        "width" => job.crop_width,
        "x" => job.crop_x,
        "y" => job.crop_y
      },
      "dither" => Atom.to_string(job.dither_mode),
      "outputFormat" => Atom.to_string(job.output_format),
      "palette" => Enum.map(job.palette, &Tuple.to_list/1),
      "profileId" => attributes.profile_id,
      "rendererRevision" => attributes.renderer_revision,
      "resizeFilter" => Atom.to_string(job.resize_filter),
      "sourceHeight" => job.source_height,
      "sourceRepresentation" => "rgba8",
      "sourceWidth" => job.source_width,
      "targetHeight" => job.target_height,
      "targetWidth" => job.target_width
    }

    parameters =
      if job.output_format == :indexed4_msb do
        Map.merge(parameters, %{
          "wireCodes" => job.wire_codes,
          "packing" => attributes.packing,
          "paletteRevision" => attributes.palette_revision,
          "colorProfileRevision" => attributes.color_profile_revision
        })
      else
        parameters
      end

    recipe =
      if binding,
        do:
          Map.put(parameters, "rendererBuildDigest", binding["manifest"]["rendererBuildDigest"]),
        else: parameters

    Library.register_recipe(library, :composition, recipe, [master_digest])
  end

  defp produce_artifact(
         library,
         renderer,
         master_digest,
         recipe_hash,
         job,
         attributes,
         nil,
         _
       ) do
    fetch_or_render(library, renderer, master_digest, recipe_hash, job, attributes, nil)
  end

  defp produce_artifact(
         library,
         renderer,
         master_digest,
         recipe_hash,
         job,
         attributes,
         binding,
         frame_id
       ) do
    with {:ok, work_digest} <-
           Library.accept_qualified_work(
             library,
             frame_id,
             binding["digest"],
             master_digest,
             recipe_hash
           ),
         {:ok, artifact} <-
           fetch_or_render(
             library,
             renderer,
             master_digest,
             recipe_hash,
             job,
             attributes,
             binding
           ),
         {:ok, result_digest} <-
           Library.record_qualified_result(library, work_digest, artifact["digest"]) do
      {:ok,
       Map.merge(artifact, %{
         work_digest: work_digest,
         qualification_digest: binding["digest"],
         result_digest: result_digest
       })}
    end
  end

  defp fetch_or_render(library, renderer, master_digest, recipe_hash, job, attributes, binding) do
    case Library.cached_artifact(
           library,
           recipe_hash,
           attributes.profile_id,
           attributes.renderer_revision
         ) do
      {:ok, artifact} ->
        {:ok, Map.put(artifact, :cache, :hit)}

      :not_found ->
        render_and_register(
          library,
          renderer,
          master_digest,
          recipe_hash,
          job,
          attributes,
          binding
        )
    end
  end

  defp render_and_register(
         library,
         renderer,
         master_digest,
         recipe_hash,
         job,
         attributes,
         binding
       ) do
    with {:ok, rendered} <- render_with_binding(renderer, job, binding),
         :ok <- validate_rendered(rendered, job) do
      Library.register_artifact(library, rendered.bytes, %{
        master_digest: master_digest,
        recipe_hash: recipe_hash,
        profile_id: attributes.profile_id,
        renderer_revision: attributes.renderer_revision,
        media_type: attributes.media_type
      })
    end
  end

  defp render_with_binding(renderer, job, nil), do: Renderer.render(renderer, job)

  defp render_with_binding(renderer, job, binding) do
    Renderer.render_qualified(renderer, job, binding["manifest"]["rendererBuildDigest"])
  end

  defp validate_rendered(rendered, job) do
    if rendered.format == job.output_format and
         rendered.width == job.target_width and rendered.height == job.target_height,
       do: :ok,
       else: {:error, :renderer_contract_mismatch}
  end
end
