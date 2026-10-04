defmodule Frameshift.LocalAPI do
  @moduledoc """
  Executes native product commands and returns authoritative shell snapshots.

  The Swift menu process invokes this boundary through authenticated local IPC.
  `snapshot/4` projects paired targets, selection, settings and searchable items
  from `Frameshift.Library`; `filtered_snapshot/3` admits exact native text and
  source/pin/frame facets. Frame membership follows retained master/artifact
  references and cannot claim current display. Clients cannot supply canonical
  library state or use a facet to change target selection and delivery intent.
  The execute variants route bounded command maps through owned library, renderer
  and explicitly configured direct-delivery services.

  ## Import and artwork custody

  Import validates source/canonical files, media type, dimensions and pixel
  identity, then copies exact bytes into `Frameshift.MasterPackage` storage.
  Source paths are temporary input and are not durable master references.
  Rendering later reads registered master bytes rather than caller-provided pixels.

  ## Still playlists

  `loopPinned` snapshots library pins; `loopArtwork` accepts 1–64 distinct active
  master IDs in explicit order. Both render before atomically queueing the complete
  cycle and its per-frame interval preference. Unsupported transfer/profile,
  missing masters and invalid intervals refuse before delivery. Pins changing
  later never rewrite an accepted set.

  `resumePlaylist` names an exact suspended revision. The library writer reuses
  its retained canonical body and artifacts, refusing stale revision, newer intent
  and changed capabilities. It does not use current pins or need a live renderer.

  ## Metadata and recovery

  `updateMetadata` edits a title and user labels against the observed revision,
  with explicit machine-observation dismissals. It returns the committed metadata
  in addition to shell state; immutable bytes, recipes and delivery remain intact.
  `restore` verifies retained bytes before returning removed artwork to search.
  Metadata and recovery reads use their own bounded authenticated IPC operations
  so ordinary snapshots never expand to arbitrary source provenance or all labels.

  Queue/reconciliation and loop commands preserve delivery/playlist
  semantics. A successful command returns an updated snapshot; input, persistence
  or unsupported-profile failures return finite errors. An unconfirmed send is
  not displayed artwork. Pairing secrets and credential material belong to the
  separate commissioning/transport boundaries, not ordinary shell snapshots.
  """

  alias Frameshift.Digest
  alias Frameshift.DirectDelivery
  alias Frameshift.Library
  alias Frameshift.MasterPackage
  alias Frameshift.Playlist.Plan
  alias Frameshift.Renderer
  alias Frameshift.Renderer.Protocol, as: RendererProtocol
  alias Frameshift.RenderPipeline
  alias Frameshift.RenderProfile

  @maximum_import_bytes 128 * 1024 * 1024
  @maximum_rgba_bytes RendererProtocol.maximum_source_pixels() * 4
  @maximum_dimension 32_768
  @maximum_pixels RendererProtocol.maximum_source_pixels()
  @instruction_key "generation.instruction"
  @selected_target_key "frame.selected"
  @maximum_loop_items 64

  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Builds the menu shell's authoritative snapshot from durable library state."
  @spec snapshot(GenServer.server(), String.t() | nil, String.t(), keyword()) :: map()
  def snapshot(
        library \\ Library,
        status_message \\ nil,
        search_query \\ "",
        search_options \\ []
      ) do
    targets = Enum.map(Library.list_paired_frames(library), &frame_target(library, &1))
    selected_target_id = selected_target_id(library, targets)
    membership = playlist_membership(library, selected_target_id)
    pinned = Library.list_pinned_masters(library, @maximum_loop_items + 1)

    %{
      "targets" => targets,
      "selectedTargetID" => selected_target_id,
      "instruction" => setting(library, @instruction_key, ""),
      "items" =>
        Enum.map(
          Library.search(library, search_query, Keyword.put(search_options, :limit, 100)),
          &library_item(&1, membership)
        ),
      "pinnedItems" =>
        Enum.map(
          Enum.take(pinned, @maximum_loop_items),
          &Map.take(library_item(&1, nil), ~w(id title digest))
        ),
      "pinnedSetTooLarge" => length(pinned) > @maximum_loop_items,
      "generationAvailability" => "notConfigured",
      "statusMessage" => status_message || default_status(targets)
    }
  end

  @doc "Intersects bounded native search facets without changing selection or intent."
  @spec filtered_snapshot(GenServer.server(), String.t(), map()) :: result()
  def filtered_snapshot(library, query, filters) do
    with :ok <- validate_filters(filters),
         :ok <- paired_filter(library, filters["frameID"]) do
      options = [
        pinned: Map.get(filters, "pinnedOnly", false),
        source_kind: filters["sourceKind"],
        frame_id: filters["frameID"]
      ]

      {:ok, snapshot(library, nil, query, options)}
    end
  end

  @doc "Refuses unsupported facet keys, types, source kinds and frame identity bounds."
  @spec validate_filters(term()) :: :ok | {:error, :invalid_request}
  def validate_filters(filters) when is_map(filters) do
    if Enum.all?(Map.keys(filters), &(&1 in ~w(pinnedOnly sourceKind frameID))) and
         is_boolean(Map.get(filters, "pinnedOnly", false)) and
         filters["sourceKind"] in [nil, "import", "generated"] and
         valid_filter_frame?(filters["frameID"]), do: :ok, else: {:error, :invalid_request}
  end

  def validate_filters(_), do: {:error, :invalid_request}

  defp valid_filter_frame?(nil), do: true
  defp valid_filter_frame?(frame) when is_binary(frame), do: byte_size(frame) in 1..128
  defp valid_filter_frame?(_), do: false

  defp paired_filter(_, nil), do: :ok

  defp paired_filter(library, frame_id) do
    case Library.get_paired_frame(library, frame_id) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  @doc "Executes a local command that does not require the renderer."
  @spec execute(GenServer.server(), map()) :: result()
  def execute(library \\ Library, command) do
    execute_with_renderer(library, Renderer, command)
  end

  @doc "Executes a local command that may render and queue a frame artifact."
  @spec execute_with_renderer(GenServer.server(), GenServer.server(), map()) :: result()
  def execute_with_renderer(library, renderer, command) do
    options = Application.get_env(:frameshift_core, :direct_delivery, [])
    execute_with_delivery(library, renderer, command, options)
  end

  @doc "Executes a command with an explicit direct-delivery broker configuration."
  @spec execute_with_delivery(GenServer.server(), GenServer.server(), map(), keyword()) ::
          result()
  def execute_with_delivery(library, renderer, command, options) do
    with :ok <- validate_command_shape(command) do
      case command do
        %{"kind" => "queue"} -> do_queue(library, renderer, command, options)
        %{"kind" => "loopPinned"} -> do_loop_pinned(library, renderer, command)
        %{"kind" => "loopArtwork"} -> do_loop_artwork(library, renderer, command)
        %{"kind" => "resumePlaylist"} -> do_resume_playlist(library, command)
        %{"kind" => "reconcileDelivery"} -> do_reconcile_delivery(library, command, options)
        _ -> do_execute(library, command)
      end
    end
  end

  defp do_execute(library, %{"kind" => "updateInstruction", "instruction" => instruction})
       when is_binary(instruction) and byte_size(instruction) <= 4_096 do
    case Library.put_setting(library, @instruction_key, instruction) do
      :ok -> {:ok, snapshot(library, "Instruction saved")}
      {:error, _} -> {:error, :persistence_failed}
    end
  end

  defp do_execute(
         library,
         %{
           "kind" => "importFile",
           "importPath" => path,
           "importWidth" => width,
           "importHeight" => height,
           "importMediaType" => media_type,
           "importCanonicalPath" => canonical_path,
           "importCanonicalDigest" => canonical_digest
         } = command
       ) do
    with :ok <- validate_import_description(path, width, height, media_type, command),
         :ok <- validate_import_path(canonical_path),
         :ok <- validate_digest(canonical_digest),
         {:ok, original} <- read_file(path, @maximum_import_bytes),
         ^media_type <- media_type(original),
         {:ok, rgba} <- read_file(canonical_path, @maximum_rgba_bytes),
         :ok <- validate_canonical(rgba, width, height, canonical_digest),
         {:ok, package} <- MasterPackage.encode(original, rgba, width, height),
         {:ok, _} <-
           Library.import_master(library, package, %{
             title: import_title(path),
             source_kind: :import,
             width: width,
             height: height,
             media_type: MasterPackage.media_type(),
             orientation: 1,
             color_profile: "sRGB",
             provenance: %{
               "kind" => "local-import",
               "originalFilename" => Path.basename(path),
               "originalMediaType" => media_type,
               "originalOrientation" => Map.get(command, "importOrientation", 1),
               "originalColorProfile" => Map.get(command, "importColorProfile"),
               "canonicalRepresentation" => "rgba8-srgb-straight-alpha-top-left"
             }
           }) do
      {:ok, snapshot(library, "Image imported into the durable library")}
    else
      nil -> {:error, :unsupported_media_type}
      detected when is_binary(detected) -> {:error, :media_type_mismatch}
      {:error, reason} -> {:error, normalize_import_error(reason)}
    end
  end

  defp do_execute(library, %{
         "kind" => "setPinned",
         "itemID" => digest,
         "isPinned" => pinned
       })
       when is_binary(digest) and is_boolean(pinned) do
    result =
      with {:ok, _} <- Library.get_master(library, digest) do
        if pinned, do: Library.pin(library, digest), else: Library.unpin(library, digest)
      end

    case result do
      :ok -> {:ok, snapshot(library, if(pinned, do: "Artwork pinned", else: "Artwork unpinned"))}
      :not_found -> {:error, :item_not_found}
      {:error, _} -> {:error, :item_not_found}
    end
  end

  defp do_execute(library, %{"kind" => "remove", "itemID" => digest})
       when is_binary(digest) do
    case Library.remove_master(library, digest) do
      :ok -> {:ok, snapshot(library, "Artwork moved to Recently Removed")}
      {:error, _} -> {:error, :item_not_found}
    end
  end

  defp do_execute(library, %{"kind" => "restore", "itemID" => digest} = command)
       when is_binary(digest) do
    case Library.restore_master(library, digest, command["id"]) do
      :ok -> {:ok, snapshot(library, "Artwork restored to the Library")}
      {:error, :not_found} -> {:error, :item_not_found}
      {:error, _} -> {:error, :restore_failed}
    end
  end

  defp do_execute(library, %{"kind" => "updateMetadata", "itemID" => digest} = command)
       when is_binary(digest) do
    case Library.update_metadata(library, digest, command) do
      {:ok, metadata} ->
        {:ok, Map.put(snapshot(library, "Artwork metadata saved"), "updatedMetadata", metadata)}

      {:error, reason}
      when reason in [:metadata_revision_conflict, :invalid_metadata, :item_not_found] ->
        {:error, reason}

      {:error, _} ->
        {:error, :metadata_unavailable}
    end
  end

  defp do_execute(library, %{"kind" => "selectTarget", "targetID" => target_id})
       when is_binary(target_id) do
    with {:ok, _} <- Library.get_paired_frame(library, target_id),
         :ok <- Library.put_setting(library, @selected_target_key, target_id) do
      {:ok, snapshot(library, "Target selected")}
    else
      :not_found -> {:error, :target_not_found}
      {:error, _} -> {:error, :persistence_failed}
    end
  end

  defp do_execute(_, %{"kind" => "selectTarget"}), do: {:error, :target_not_found}
  defp do_execute(_, _), do: {:error, :invalid_command}

  defp do_queue(
         library,
         renderer,
         %{"targetID" => target_id, "itemID" => master_digest} = command,
         options
       )
       when is_binary(target_id) and is_binary(master_digest) do
    with {:ok, frame} <- fetch_target(library, target_id),
         {:ok, binding} <- queue_binding(library, frame["frame_id"]),
         {:ok, mode} <- delivery_mode(frame, command, options, binding),
         {:ok, master} <- fetch_master(library, master_digest),
         {:ok, compilation} <-
           RenderProfile.compile(master, frame["capabilities"], binding_profile_id(binding)),
         {:ok, artifact} <-
           render_for_queue(library, renderer, frame, mode, master_digest, compilation, binding),
         {:ok, status} <-
           deliver(library, frame, artifact, compilation.profile, command, mode, options) do
      {:ok, snapshot(library, status)}
    else
      {:error, reason} -> {:error, normalize_queue_error(reason)}
    end
  end

  defp do_queue(_, _, _, _), do: {:error, :invalid_command}

  defp do_loop_pinned(library, renderer, %{"targetID" => target_id} = command)
       when is_binary(target_id) do
    with {:ok, frame} <- fetch_target(library, target_id),
         :ok <- require_pull_loop(frame),
         {:ok, binding} <- queue_binding(library, target_id),
         :ok <- require_pull_binding(binding),
         {:ok, pinned} <- pinned_for_loop(library, frame),
         {:ok, result} <- prepare_loop(library, renderer, frame, binding, pinned, command) do
      {:ok, result}
    else
      {:error, reason} -> {:error, normalize_queue_error(reason)}
    end
  end

  defp do_loop_pinned(_, _, _), do: {:error, :invalid_command}

  defp do_loop_artwork(library, renderer, %{"targetID" => target_id, "itemIDs" => ids} = command)
       when is_binary(target_id) and is_list(ids) do
    with :ok <- validate_loop_ids(ids),
         {:ok, frame} <- fetch_target(library, target_id),
         :ok <- require_pull_loop(frame),
         true <- length(ids) <= frame["capabilities"]["storage"]["maximumPlaylistLength"],
         {:ok, binding} <- queue_binding(library, target_id),
         :ok <- require_pull_binding(binding),
         {:ok, masters} <- masters_for_loop(library, ids),
         {:ok, result} <- prepare_loop(library, renderer, frame, binding, masters, command) do
      {:ok, result}
    else
      false -> {:error, :playlist_too_long}
      {:error, reason} -> {:error, normalize_queue_error(reason)}
    end
  end

  defp do_loop_artwork(_, _, _), do: {:error, :invalid_command}

  defp validate_loop_ids(ids) do
    if length(ids) in 1..@maximum_loop_items and
         length(Enum.uniq(ids)) == length(ids) and Enum.all?(ids, &Digest.valid_sha256?/1),
       do: :ok,
       else: {:error, :invalid_command}
  end

  defp masters_for_loop(library, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, masters} ->
      case fetch_master(library, id) do
        {:ok, %{"removed_at_ms" => nil} = master} -> {:cont, {:ok, [master | masters]}}
        _ -> {:halt, {:error, :item_not_found}}
      end
    end)
    |> then(fn
      {:ok, masters} -> {:ok, Enum.reverse(masters)}
      error -> error
    end)
  end

  defp prepare_loop(library, renderer, frame, binding, masters, command) do
    requested = Map.get(command, "dwellMs")

    with {:ok, _, _, _} <- Plan.resolve_dwell(frame["capabilities"], requested),
         {:ok, rendered} <- render_pinned(library, renderer, frame, binding, masters),
         {:ok, plan} <-
           Plan.build(
             frame["capabilities"],
             Enum.map(rendered, & &1["artifactDigest"]),
             requested
           ),
         {:ok, _} <-
           Library.queue_playlist(
             library,
             frame["frame_id"],
             binding_profile_id(binding) || selected_profile_id(frame["capabilities"]),
             plan.playlist,
             rendered,
             Map.get(command, "id"),
             if(requested == nil, do: :profile, else: {:override, requested})
           ) do
      {:ok, snapshot(library, "Artwork loop queued for #{frame["title"]}")}
    else
      {:error, reason} -> {:error, normalize_queue_error(reason)}
    end
  end

  defp do_resume_playlist(
         library,
         %{"targetID" => target_id, "playlistRevision" => revision} = command
       )
       when is_binary(target_id) and is_binary(revision) do
    with true <- Digest.valid_sha256?(revision),
         {:ok, frame} <- fetch_target(library, target_id),
         {:ok, _} <- Library.resume_playlist(library, target_id, revision, command["id"]) do
      {:ok, snapshot(library, "Saved loop queued for #{frame["title"]} • waiting for frame")}
    else
      false -> {:error, :invalid_command}
      {:error, reason} -> {:error, normalize_queue_error(reason)}
    end
  end

  defp do_resume_playlist(_, _), do: {:error, :invalid_command}

  defp require_pull_loop(%{"capabilities" => %{"transferModes" => modes}}) do
    if "pull" in modes, do: :ok, else: {:error, :pull_not_supported}
  end

  defp require_pull_binding(nil), do: :ok

  defp require_pull_binding(%{"manifest" => %{"transferMode" => "pull"}}), do: :ok
  defp require_pull_binding(_), do: {:error, :compatible_binding_unavailable}

  defp pinned_for_loop(library, frame) do
    limit = min(frame["capabilities"]["storage"]["maximumPlaylistLength"], @maximum_loop_items)
    pinned = Library.list_pinned_masters(library, limit + 1)

    cond do
      pinned == [] -> {:error, :no_pinned_artwork}
      length(pinned) > limit -> {:error, :playlist_too_long}
      true -> {:ok, pinned}
    end
  end

  defp render_pinned(library, renderer, frame, binding, masters) do
    Enum.reduce_while(masters, {:ok, []}, fn master, {:ok, entries} ->
      case render_pinned_master(library, renderer, frame, binding, master) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end)
  end

  defp render_pinned_master(library, renderer, frame, binding, master) do
    with {:ok, compilation} <-
           RenderProfile.compile(master, frame["capabilities"], binding_profile_id(binding)),
         {:ok, artifact} <-
           render_for_queue(
             library,
             renderer,
             frame,
             :pull,
             master["digest"],
             compilation,
             binding
           ) do
      {:ok,
       %{
         "masterDigest" => master["digest"],
         "artifactDigest" => artifact["digest"],
         "workDigest" => Map.get(artifact, :work_digest)
       }}
    end
  end

  defp queue_binding(library, frame_id) do
    case Library.active_qualification(library, frame_id) do
      {:ok, binding} -> {:ok, binding}
      :not_found -> {:ok, nil}
    end
  end

  defp binding_profile_id(nil), do: nil
  defp binding_profile_id(binding), do: binding["manifest"]["profileId"]

  defp render_for_queue(library, renderer, frame, mode, master_digest, compilation, binding) do
    if binding do
      RenderPipeline.render_qualified_stored_master(
        library,
        renderer,
        frame["frame_id"],
        Atom.to_string(mode),
        master_digest,
        compilation.job,
        compilation.attributes
      )
    else
      RenderPipeline.render_stored_master(
        library,
        renderer,
        master_digest,
        compilation.job,
        compilation.attributes
      )
    end
  end

  defp delivery_mode(frame, command, options, nil),
    do: delivery_mode(frame, command, options)

  defp delivery_mode(%{"capabilities" => %{"transferModes" => modes}}, command, options, binding) do
    case binding["manifest"]["transferMode"] do
      "pull" ->
        if "pull" in modes, do: {:ok, :pull}, else: {:error, :compatible_binding_unavailable}

      "push" ->
        if "push" in modes,
          do: push_delivery_mode(command, options),
          else: {:error, :compatible_binding_unavailable}

      _ ->
        {:error, :compatible_binding_unavailable}
    end
  end

  defp push_delivery_mode(command, options) do
    cond do
      not Keyword.has_key?(options, :credential_resolver) ->
        {:error, :credential_broker_unavailable}

      not is_binary(Map.get(command, "id")) ->
        {:error, :invalid_command}

      true ->
        {:ok, :push}
    end
  end

  defp do_reconcile_delivery(library, %{"targetID" => target_id}, options)
       when is_binary(target_id) do
    case DirectDelivery.reconcile(library, target_id, options) do
      {:ok, :displayed} -> {:ok, snapshot(library, "Display confirmed")}
      {:ok, :pending} -> {:ok, snapshot(library, "Display confirmation still pending")}
      {:error, reason} -> {:error, normalize_queue_error(reason)}
    end
  end

  defp do_reconcile_delivery(_, _, _), do: {:error, :invalid_command}

  defp validate_command_shape(%{"kind" => kind} = command) when is_binary(kind) do
    id = Map.get(command, "id")
    allowed = allowed_command_keys(kind)

    cond do
      id != nil and (not is_binary(id) or byte_size(id) not in 1..64) ->
        {:error, :invalid_command}

      Enum.any?(Map.keys(command), &(&1 not in allowed)) ->
        {:error, :invalid_command}

      true ->
        :ok
    end
  end

  defp validate_command_shape(_), do: {:error, :invalid_command}

  defp allowed_command_keys("updateInstruction"), do: ~w(id kind instruction)

  defp allowed_command_keys("importFile") do
    ~w(id kind importPath importWidth importHeight importMediaType importOrientation importColorProfile importCanonicalPath importCanonicalDigest)
  end

  defp allowed_command_keys("setPinned"), do: ~w(id kind itemID isPinned)
  defp allowed_command_keys("remove"), do: ~w(id kind itemID)
  defp allowed_command_keys("restore"), do: ~w(id kind itemID)

  defp allowed_command_keys("updateMetadata"),
    do: ~w(id kind itemID metadataRevision title userLabels dismissedLabels)

  defp allowed_command_keys("selectTarget"), do: ~w(id kind targetID)
  defp allowed_command_keys("queue"), do: ~w(id kind targetID itemID)
  defp allowed_command_keys("loopPinned"), do: ~w(id kind targetID dwellMs)
  defp allowed_command_keys("loopArtwork"), do: ~w(id kind targetID itemIDs dwellMs)
  defp allowed_command_keys("resumePlaylist"), do: ~w(id kind targetID playlistRevision)
  defp allowed_command_keys("reconcileDelivery"), do: ~w(id kind targetID)
  defp allowed_command_keys(_), do: ~w(id kind)

  defp setting(library, key, default) do
    case Library.get_setting(library, key) do
      {:ok, value} -> value
      :not_found -> default
      {:error, _} -> default
    end
  end

  defp playlist_membership(_, nil), do: nil

  defp playlist_membership(library, frame_id),
    do: Library.frame_playlist_members(library, frame_id)

  defp library_item(master, membership) do
    %{
      "id" => master["digest"],
      "title" => master["title"],
      "digest" => master["digest"],
      "isPinned" => master["pinned"],
      "queuedTargetID" => master["queued_target_id"],
      "loopStatus" => loop_status(master["digest"], membership)
    }
  end

  defp loop_status(digest, %{"status" => state, "masterDigests" => members}) do
    if digest in members, do: state, else: nil
  end

  defp loop_status(_, _), do: nil

  defp frame_target(library, frame) do
    {:ok, binding} = queue_binding(library, frame["frame_id"])
    profile_id = binding_profile_id(binding) || selected_profile_id(frame["capabilities"])

    %{
      "id" => frame["frame_id"],
      "name" => frame["title"],
      "medium" => frame["medium"],
      "profileID" => profile_id,
      "capabilityDigest" => Digest.sha256(RFC8785.encode!(frame["capabilities"])),
      "state" => frame["connection_state"],
      "minimumDwellMs" => frame["capabilities"]["refresh"]["minimumDwellMs"],
      "maximumPlaylistLength" =>
        min(frame["capabilities"]["storage"]["maximumPlaylistLength"], @maximum_loop_items),
      "recommendedDwellMs" => frame["capabilities"]["refresh"]["recommendedDwellMs"],
      "recommendationBasis" => frame["capabilities"]["refresh"]["recommendationBasis"],
      "recommendationRevision" => frame["capabilities"]["refresh"]["recommendationRevision"],
      "playlist" => Library.frame_playlist_status(library, frame["frame_id"]),
      "loopInterval" => Library.frame_playlist_interval(library, frame["frame_id"]),
      "hasQueuedDelivery" => Library.outbox_manifest(library, frame["frame_id"]) != :empty,
      "directDelivery" => direct_delivery_summary(library, frame["frame_id"])
    }
  end

  defp direct_delivery_summary(library, frame_id) do
    case Library.direct_delivery(library, frame_id) do
      {:ok, delivery} ->
        %{
          "status" => delivery["status"],
          "revision" => delivery["revision"],
          "desiredDigest" => delivery["desired_digest"]
        }

      :not_found ->
        nil
    end
  end

  defp selected_target_id(library, targets) do
    selected = setting(library, @selected_target_key, nil)

    if Enum.any?(targets, &(&1["id"] == selected)),
      do: selected,
      else: targets |> List.first() |> then(&if(&1, do: &1["id"], else: nil))
  end

  defp default_status([]), do: "Core connected • library ready"
  defp default_status(_), do: "Core connected • paired frames ready"

  defp selected_profile_id(capabilities) do
    case RenderProfile.compile(%{"width" => 1, "height" => 1}, capabilities) do
      {:ok, compilation} -> compilation.profile["id"]
      {:error, _} -> capabilities["storage"]["artifactProfiles"] |> hd() |> Map.fetch!("id")
    end
  end

  defp delivery_mode(%{"capabilities" => %{"transferModes" => modes}}, command, options) do
    cond do
      "pull" in modes ->
        {:ok, :pull}

      "push" in modes and Keyword.has_key?(options, :credential_resolver) and
          is_binary(Map.get(command, "id")) ->
        {:ok, :push}

      "push" in modes and not Keyword.has_key?(options, :credential_resolver) ->
        {:error, :credential_broker_unavailable}

      "push" in modes ->
        {:error, :invalid_command}

      true ->
        {:error, :compatible_binding_unavailable}
    end
  end

  defp deliver(library, frame, artifact, profile, command, :pull, _) do
    case Library.queue_outbox(
           library,
           frame["frame_id"],
           artifact["digest"],
           profile["id"],
           nil,
           command["id"],
           Map.get(artifact, :work_digest)
         ) do
      {:ok, _} ->
        {:ok, "Queued for #{frame["title"]} • waiting for next contact"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(library, frame, artifact, profile, command, :push, options) do
    case DirectDelivery.push(library, frame, artifact, profile, command["id"], options) do
      {:ok, :displayed} -> {:ok, "Displayed on #{frame["title"]}"}
      {:ok, :pending} -> {:ok, "Sent to #{frame["title"]} • refresh pending"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_target(library, target_id) do
    case Library.get_paired_frame(library, target_id) do
      {:ok, frame} -> {:ok, frame}
      :not_found -> {:error, :target_not_found}
    end
  end

  defp fetch_master(library, master_digest) do
    case Library.get_master(library, master_digest) do
      {:ok, master} -> {:ok, master}
      :not_found -> {:error, :item_not_found}
    end
  end

  defp normalize_queue_error(reason)
       when reason in [
              :target_not_found,
              :invalid_command,
              :item_not_found,
              :unsupported_profile,
              :compatible_binding_unavailable,
              :master_missing,
              :source_dimensions_mismatch,
              :unsupported_source_representation,
              :artifact_missing,
              :credential_broker_unavailable,
              :invalid_request_id,
              :invalid_frame_origin,
              :authentication_required,
              :request_id_conflict,
              :direct_delivery_pending,
              :direct_delivery_not_pending,
              :direct_delivery_conflict,
              :no_pinned_artwork,
              :playlist_too_long,
              :interval_required,
              :invalid_interval,
              :pull_not_supported,
              :frame_not_paired,
              :storage_full,
              :already_active,
              :playlist_pending,
              :playlist_revision_conflict,
              :playlist_profile_changed,
              :duplicate_artifact
            ],
       do: reason

  defp normalize_queue_error({:transport, _}), do: :delivery_outcome_unknown

  defp normalize_queue_error(:state_unavailable), do: :delivery_outcome_unknown

  defp normalize_queue_error(reason) when reason in [:timeout, :direct_sync_failure],
    do: :delivery_outcome_unknown

  defp normalize_queue_error(reason)
       when reason in [:credential_broker_failure, :credential_broker_contract_violation],
       do: :credential_broker_unavailable

  defp normalize_queue_error(_), do: :queue_failed

  defp validate_import_description(path, width, height, media_type, command) do
    orientation = Map.get(command, "importOrientation", 1)
    color_profile = Map.get(command, "importColorProfile")

    with :ok <- validate_import_path(path),
         :ok <- validate_import_dimensions(width, height),
         :ok <- validate_import_media_type(media_type),
         :ok <- validate_import_orientation(orientation) do
      validate_import_color_profile(color_profile)
    end
  end

  defp validate_import_path(path)
       when is_binary(path) and byte_size(path) in 1..1_024,
       do: :ok

  defp validate_import_path(_), do: {:error, :invalid_import}

  defp validate_import_dimensions(width, height)
       when is_integer(width) and is_integer(height) and width in 1..@maximum_dimension and
              height in 1..@maximum_dimension and width * height <= @maximum_pixels,
       do: :ok

  defp validate_import_dimensions(_, _), do: {:error, :invalid_dimensions}

  defp validate_import_media_type(media_type)
       when is_binary(media_type) and byte_size(media_type) <= 128,
       do: :ok

  defp validate_import_media_type(_), do: {:error, :unsupported_media_type}

  defp validate_import_orientation(orientation) when orientation in 1..8, do: :ok
  defp validate_import_orientation(_), do: {:error, :invalid_orientation}

  defp validate_import_color_profile(nil), do: :ok

  defp validate_import_color_profile(color_profile)
       when is_binary(color_profile) and byte_size(color_profile) <= 256,
       do: :ok

  defp validate_import_color_profile(_), do: {:error, :invalid_color_profile}

  defp read_file(path, maximum_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          with {:ok, info} <- :file.read_file_info(file),
               stat = File.Stat.from_record(info),
               :ok <- validate_import_stat(stat, maximum_bytes),
               bytes when is_binary(bytes) <- IO.binread(file, stat.size + 1),
               true <- byte_size(bytes) == stat.size do
            {:ok, bytes}
          else
            :eof -> {:error, :import_changed}
            false -> {:error, :import_changed}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_import_stat(%File.Stat{type: :regular, size: size}, maximum_bytes)
       when size > 0 and size <= maximum_bytes,
       do: :ok

  defp validate_import_stat(%File.Stat{type: :regular}, _),
    do: {:error, :import_too_large}

  defp validate_import_stat(%File.Stat{}, _), do: {:error, :import_not_regular}

  defp validate_digest(digest) do
    if Digest.valid_sha256?(digest), do: :ok, else: {:error, :invalid_import}
  end

  defp validate_canonical(rgba, width, height, expected_digest) do
    cond do
      byte_size(rgba) != width * height * 4 -> {:error, :invalid_canonical_image}
      Digest.sha256(rgba) != expected_digest -> {:error, :canonical_digest_mismatch}
      true -> :ok
    end
  end

  defp media_type(<<137, "PNG\r\n", 26, 10, _::binary>>), do: "image/png"
  defp media_type(<<255, 216, 255, _::binary>>), do: "image/jpeg"
  defp media_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp media_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp media_type(<<"II", 42, 0, _::binary>>), do: "image/tiff"
  defp media_type(<<"MM", 0, 42, _::binary>>), do: "image/tiff"
  defp media_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"

  defp media_type(<<_::unsigned-big-32, "ftyp", brand::binary-size(4), _::binary>>)
       when brand in ["heic", "heix", "hevc", "hevx"],
       do: "image/heic"

  defp media_type(<<_::unsigned-big-32, "ftyp", brand::binary-size(4), _::binary>>)
       when brand in ["mif1", "msf1"],
       do: "image/heif"

  defp media_type(_), do: nil

  defp import_title(path) do
    case path |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> "Imported image"
      title -> String.slice(title, 0, 256)
    end
  end

  defp normalize_import_error(reason)
       when reason in [
              :invalid_import,
              :invalid_dimensions,
              :invalid_orientation,
              :invalid_color_profile,
              :invalid_canonical_image,
              :canonical_digest_mismatch,
              :unsupported_media_type,
              :import_too_large,
              :import_not_regular,
              :import_changed
            ],
       do: reason

  defp normalize_import_error(_), do: :import_unreadable
end
