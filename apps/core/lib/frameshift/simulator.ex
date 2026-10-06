defmodule Frameshift.Simulator do
  @moduledoc """
  Models persistent frame protocol behavior with explicit fault injection.

  `start_link/1` receives advertised capabilities and a data directory. The frame
  verifies immutable artifacts within declared storage/profile limits and retains
  separate desired, current and previous-known-good assets. State exposes a strong
  revision ETag; desired/playlist changes require the corresponding precondition.
  Closed indexed4 assets additionally require exact even-row length and declared
  pigment codes in both nibbles. Invalid packing, lengths or codes refuse before
  content publication, desired-state changes or simulated display completion.

  ## Artifact profile custody

  Each installed artifact freezes the canonical profile/color/geometry digest
  from `Frameshift.Qualification.Profile.digest/2`. Cache hits and every activation
  path compare that identity, including idempotent requests and outbox replay.
  Changed or missing identity retains bytes and artwork pointers after restart,
  reports recovering/degraded state, and refuses fresh display confirmation.
  Reinstalling conflicting metadata preserves the original association. Storage
  degradation persists; a later successful display does not claim it was repaired.

  ## Exercising receiver behavior

  Asset, desired, retry, playlist and pull-outbox operations model bounded transfer,
  activation and receiver-owned dwell. `set_faults/2` injects contact, storage,
  transfer, display and power interruptions. Restart loads checksummed artwork
  state rather than treating an interrupted display as newly completed.

  Pairing is separately modeled with a physical-only window and fail-closed
  single-use authority; an older artwork slot cannot restore a consumed secret.
  The authenticated TD is available only to the admitted host certificate.

  Use this process for deterministic protocol/recovery fixtures. It does not prove
  physical panel timing, optics, flash durability or an independent production TLS
  stack. The container receiver exercises a separate process/transport profile;
  exact hardware still requires its own measurements and firmware qualification.
  """

  use GenServer

  alias Frameshift.ContentStore
  alias Frameshift.Digest
  alias Frameshift.Pairing.{Endpoint, Store, Window}
  alias Frameshift.Protocol.Schema
  alias Frameshift.Protocol.Thing
  alias Frameshift.Qualification.Profile
  alias Frameshift.Simulator.Persistence
  alias Frameshift.Simulator.State
  alias Wotex.ThingDescription

  @allowed_faults [
    :corrupt_upload,
    :display_failure,
    :missed_contact,
    :power_loss_at,
    :slow_refresh_ms,
    :storage_full
  ]

  @type server :: GenServer.server()

  @doc "Starts a persistent software frame with injected capabilities and optional fault state."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    with {:ok, capabilities} <- Keyword.fetch(options, :capabilities),
         :ok <- Schema.validate("capabilities", capabilities) do
      case Keyword.get(options, :name, __MODULE__) do
        nil -> GenServer.start_link(__MODULE__, options)
        name -> GenServer.start_link(__MODULE__, options, name: name)
      end
    else
      :error -> {:error, :capabilities_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the frame's advertised capabilities."
  @spec capabilities(server()) :: map()
  def capabilities(server \\ __MODULE__), do: GenServer.call(server, :capabilities)

  @doc "Returns current display truth with its strong revision ETag."
  @spec state(server()) :: %{state: map(), etag: String.t()}
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "Injects contact, transfer, storage, display, or power faults for deterministic tests."
  @spec set_faults(server(), map()) :: :ok | {:error, term()}
  def set_faults(server \\ __MODULE__, faults), do: GenServer.call(server, {:set_faults, faults})

  @doc "Verifies and stores one digest addressed artifact under the frame's storage limits."
  @spec put_asset(server(), String.t(), String.t(), binary()) ::
          {:ok, :created | :existing} | {:error, term()}
  def put_asset(server \\ __MODULE__, digest, profile_id, bytes) do
    GenServer.call(server, {:put_asset, digest, profile_id, bytes}, :infinity)
  end

  @doc "Reports whether a verified artifact is present."
  @spec has_asset?(server(), String.t()) :: boolean()
  def has_asset?(server \\ __MODULE__, digest), do: GenServer.call(server, {:has_asset, digest})

  @doc "Checks whether an artifact is already verified for the advertised profile."
  @spec has_compatible_asset?(server(), String.t(), String.t()) :: boolean()
  def has_compatible_asset?(server \\ __MODULE__, digest, profile_id),
    do: GenServer.call(server, {:has_compatible_asset, digest, profile_id})

  @doc "Deletes an unreferenced artifact from simulated storage."
  @spec delete_asset(server(), String.t()) :: :ok | {:error, term()}
  def delete_asset(server \\ __MODULE__, digest),
    do: GenServer.call(server, {:delete_asset, digest})

  @doc "Applies desired state under an ETag precondition and attempts a display transition."
  @spec set_desired(server(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_desired(server \\ __MODULE__, request, precondition) do
    GenServer.call(server, {:set_desired, request, precondition}, :infinity)
  end

  @doc "Retries an interrupted display while preserving the prior known good image."
  @spec retry_display(server()) :: {:ok, map()} | {:error, term()}
  def retry_display(server \\ __MODULE__), do: GenServer.call(server, :retry_display, :infinity)

  @doc "Updates a still playlist under a revision precondition."
  @spec set_playlist(server(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_playlist(server \\ __MODULE__, playlist, precondition) do
    GenServer.call(server, {:set_playlist, playlist, precondition})
  end

  @doc "Advances at most one cached still at a receiver-owned RTC tick."
  @spec advance_playlist(server(), non_neg_integer()) ::
          {:ok, :waiting | :suspended | map()} | {:error, term()}
  def advance_playlist(server \\ __MODULE__, now_ms) do
    GenServer.call(server, {:advance_playlist, now_ms}, :infinity)
  end

  @doc "Models a sleeping frame's contact, artifact pull, and manifest acknowledgement."
  @spec pull_outbox(server(), map(), binary() | nil) ::
          {:ok, :no_work | map()} | {:error, term()}
  def pull_outbox(server \\ __MODULE__, manifest, bytes) do
    GenServer.call(server, {:pull_outbox, manifest, bytes}, :infinity)
  end

  @doc "Opens pairing after a physical action; this is never exposed as a network operation."
  @spec open_pairing(server(), non_neg_integer()) :: :ok | {:error, term()}
  def open_pairing(server \\ __MODULE__, now_ms),
    do: GenServer.call(server, {:open_pairing, now_ms})

  @doc "Applies a pre-pair body supplied with the TLS-authenticated peer certificate."
  @spec pair(server(), binary(), binary(), non_neg_integer()) ::
          {:ok, Endpoint.response()} | {:error, term()}
  def pair(server \\ __MODULE__, peer_der, body, now_ms),
    do: GenServer.call(server, {:pair, peer_der, body, now_ms})

  @doc "Returns the full TD only to the exact TLS certificate admitted by physical pairing."
  @spec authorized_thing(server(), binary()) :: {:ok, binary()} | {:error, :not_authorized}
  def authorized_thing(server \\ __MODULE__, peer_der),
    do: GenServer.call(server, {:authorized_thing, peer_der})

  @doc "Sets a simulator introduction after its ephemeral listener port is known, before pairing."
  @spec set_thing_source(server(), binary()) :: :ok | {:error, atom()}
  def set_thing_source(server \\ __MODULE__, source),
    do: GenServer.call(server, {:set_thing_source, source})

  @impl true
  def init(options) do
    capabilities = Keyword.fetch!(options, :capabilities)
    data_dir = options |> Keyword.fetch!(:data_dir) |> Path.expand()

    with :ok <- Schema.validate("capabilities", capabilities),
         :ok <- ContentStore.prepare(data_dir),
         {:ok, state} <- load_state(data_dir, capabilities),
         {:ok, pairing} <-
           Store.load_or_create(
             data_dir,
             capabilities["deviceId"],
             Keyword.get(options, :pairing_secret)
           ),
         {:ok, thing_source} <- validate_thing(Keyword.get(options, :thing_source), capabilities),
         :ok <- verify_assets(state),
         {:ok, interrupted} <- recover_interrupted(state),
         {:ok, recovered} <- recover_profiles(interrupted) do
      {:ok, %{recovered | pairing: pairing, thing_source: thing_source}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:capabilities, _, state), do: {:reply, state.capabilities, state}

  def handle_call({:open_pairing, _}, _, %{pairing: nil} = state),
    do: {:reply, {:error, :pairing_not_configured}, state}

  def handle_call({:open_pairing, now_ms}, _, state) do
    case Window.open(state.pairing, now_ms) do
      {:ok, opened} -> {:reply, :ok, %{state | pairing: opened}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pair, _, _, _}, _, %{pairing: nil} = state),
    do: {:reply, {:error, :pairing_not_configured}, state}

  def handle_call({:pair, peer_der, body, now_ms}, _, state) do
    {response, next} = Endpoint.handle(state.pairing, peer_der, body, now_ms)

    if next == state.pairing do
      {:reply, {:ok, response}, state}
    else
      case Store.save(state.data_dir, next) do
        :ok ->
          {:reply, {:ok, response}, %{state | pairing: next}}

        {:error, {:commit_uncertain, reason}} ->
          {:stop, {:pairing_commit_uncertain, reason}, {:error, :pairing_commit_uncertain}, state}

        {:error, reason} ->
          {:reply, {:error, {:pairing_persistence_failed, reason}}, state}
      end
    end
  end

  def handle_call({:authorized_thing, peer_der}, _, state) do
    {:reply, authorized_thing_record(state, peer_der), state}
  end

  def handle_call(
        {:set_thing_source, source},
        _,
        %{thing_source: nil, pairing: %Window{host_certificate_fingerprint: nil}} = state
      ) do
    case validate_thing(source, state.capabilities) do
      {:ok, accepted} -> {:reply, :ok, %{state | thing_source: accepted}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_thing_source, _}, _, state),
    do: {:reply, {:error, :thing_already_configured}, state}

  def handle_call(:state, _, state) do
    {:reply, %{state: State.public(state), etag: State.etag(state)}, state}
  end

  def handle_call({:set_faults, faults}, _, state) do
    if valid_faults?(faults),
      do: {:reply, :ok, %{state | faults: faults}},
      else: {:reply, {:error, :invalid_faults}, state}
  end

  def handle_call({:has_asset, digest}, _, state) do
    {:reply, Map.has_key?(state.assets, digest), state}
  end

  def handle_call({:has_compatible_asset, digest, profile_id}, _, state) do
    {:reply, asset_compatible?(state, digest, profile_id), state}
  end

  def handle_call({:put_asset, digest, profile_id, bytes}, _, state) do
    case put_asset_record(state, digest, profile_id, bytes) do
      {:ok, disposition, next_state} -> {:reply, {:ok, disposition}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_asset, digest}, _, state) do
    case delete_asset_record(state, digest) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_desired, request, precondition}, _, state) do
    case set_desired_record(state, request, precondition, true) do
      {:ok, next_state} -> {:reply, {:ok, State.public(next_state)}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:retry_display, _, %{desired_asset: nil} = state) do
    {:reply, {:error, :asset_missing}, state}
  end

  def handle_call(:retry_display, _, state) do
    case retry_display_record(state) do
      {:ok, next_state} -> {:reply, {:ok, State.public(next_state)}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:set_playlist, playlist, precondition}, _, state) do
    case set_playlist_record(state, playlist, precondition) do
      {:ok, next_state} -> {:reply, {:ok, State.public(next_state)}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:advance_playlist, now_ms}, _, state) do
    case advance_playlist_record(state, now_ms) do
      {:ok, disposition, next_state} -> {:reply, {:ok, disposition}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pull_outbox, manifest, bytes}, _, state) do
    case pull_outbox_record(state, manifest, bytes) do
      {:ok, acknowledgement, next_state} ->
        {:reply, {:ok, acknowledgement}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp authorized_thing_record(
         %{pairing: %Window{host_certificate_fingerprint: fingerprint}, thing_source: source},
         peer_der
       )
       when is_binary(fingerprint) and is_binary(source) and is_binary(peer_der) and
              byte_size(peer_der) in 1..65_536 do
    presented = "sha256:" <> Base.encode16(:crypto.hash(:sha256, peer_der), case: :lower)
    if presented == fingerprint, do: {:ok, source}, else: {:error, :not_authorized}
  end

  defp authorized_thing_record(_, _), do: {:error, :not_authorized}

  defp validate_thing(nil, _), do: {:ok, nil}

  defp validate_thing(source, capabilities) when is_binary(source) do
    with true <- byte_size(source) in 1..262_144,
         {:ok, thing} <- Thing.parse_frame(source),
         %{"frameshift:capabilities" => advertised} <- ThingDescription.to_map(thing),
         true <- capability_subset?(advertised, capabilities) do
      {:ok, source}
    else
      _ -> {:error, :invalid_thing_description}
    end
  end

  defp validate_thing(_, _), do: {:error, :invalid_thing_description}

  defp capability_subset?(advertised, actual)
       when is_map(advertised) and is_map(actual) do
    Enum.all?(advertised, fn {key, value} ->
      case Map.fetch(actual, key) do
        {:ok, actual_value} -> capability_subset?(value, actual_value)
        :error -> false
      end
    end)
  end

  defp capability_subset?(advertised, actual)
       when is_list(advertised) and is_list(actual) do
    length(advertised) == length(actual) and
      Enum.zip(advertised, actual)
      |> Enum.all?(fn {left, right} -> capability_subset?(left, right) end)
  end

  defp capability_subset?(advertised, actual), do: advertised == actual

  defp load_state(data_dir, capabilities) do
    case Persistence.load(data_dir) do
      :empty -> {:ok, State.new(capabilities, data_dir)}
      {:ok, payload} -> {:ok, State.from_persisted(payload, capabilities, data_dir)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_interrupted(%{display_state: display_state} = state)
       when display_state in ["preparing", "refreshing"] do
    recovered =
      state
      |> Map.put(:display_state, "recovering")
      |> Map.put(:last_error, problem("power-interrupted", "Display outcome requires recovery"))
      |> State.bump()

    case Persistence.save(recovered) do
      :ok -> {:ok, recovered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_interrupted(state), do: {:ok, state}

  defp recover_profiles(state) do
    if Enum.any?(state.assets, fn {digest, asset} ->
         not asset_compatible?(state, digest, asset["profileId"])
       end) do
      recovered = %{
        state
        | storage_degraded: true,
          display_state: "recovering",
          last_error: problem("unsupported-profile", "Stored artwork requires profile recovery")
      }

      persist_recovery(state, recovered)
    else
      {:ok, state}
    end
  end

  defp persist_recovery(state, state), do: {:ok, state}

  defp persist_recovery(_, recovered) do
    next_state = State.bump(recovered)

    case Persistence.save(next_state) do
      :ok -> {:ok, next_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_assets(state) do
    case Enum.find(Map.keys(state.assets), fn digest ->
           not File.regular?(ContentStore.object_path(state.data_dir, digest))
         end) do
      nil -> :ok
      digest -> {:error, {:asset_missing, digest}}
    end
  end

  defp valid_faults?(faults) when is_map(faults) do
    Enum.all?(Map.keys(faults), &(&1 in @allowed_faults)) and
      Enum.all?(
        [:corrupt_upload, :display_failure, :missed_contact, :storage_full],
        &(Map.get(faults, &1) in [nil, true, false])
      ) and
      valid_slow_refresh?(Map.get(faults, :slow_refresh_ms, 0)) and
      Map.get(faults, :power_loss_at) in [nil, :after_desired, :during_refresh, :after_refresh]
  end

  defp valid_faults?(_), do: false

  defp valid_slow_refresh?(milliseconds),
    do: is_integer(milliseconds) and milliseconds >= 0 and milliseconds <= 60_000

  defp put_asset_record(state, digest, profile_id, bytes) when is_binary(bytes) do
    candidate = if state.faults[:corrupt_upload], do: bytes <> <<0>>, else: bytes

    with true <- Digest.valid_sha256?(digest),
         true <- Digest.sha256(candidate) == digest,
         {:ok, profile} <- find_profile(state, profile_id),
         :ok <- validate_asset_size(profile, candidate),
         :ok <- validate_packed_codes(state.capabilities, profile, candidate),
         :ok <- validate_existing_metadata(state, digest, profile_id),
         :ok <- ensure_storage(state, digest, byte_size(candidate)),
         {:ok, _, byte_count, placement} <- ContentStore.put(state.data_dir, candidate) do
      commit_asset(state, digest, profile_id, byte_count, placement)
    else
      false -> {:error, :digest_mismatch}
      :not_found -> {:error, :unsupported_profile}
      {:error, :asset_metadata_conflict} -> record_metadata_conflict(state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_asset_record(_, _, _, _), do: {:error, :invalid_asset}

  defp find_profile(state, profile_id) do
    case Enum.filter(state.capabilities["storage"]["artifactProfiles"], &(&1["id"] == profile_id)) do
      [profile] -> {:ok, profile}
      _ -> :not_found
    end
  end

  defp asset_compatible?(state, digest, profile_id) do
    with %{"profileId" => ^profile_id, "profileDigest" => stored_digest} <- state.assets[digest],
         {:ok, _} <- find_profile(state, profile_id),
         {:ok, ^stored_digest} <- Profile.digest(state.capabilities, profile_id) do
      true
    else
      _ -> false
    end
  end

  defp validate_existing_metadata(state, digest, profile_id) do
    if not Map.has_key?(state.assets, digest) or asset_compatible?(state, digest, profile_id),
      do: :ok,
      else: {:error, :asset_metadata_conflict}
  end

  defp record_metadata_conflict(state) do
    degraded =
      state
      |> Map.put(:storage_degraded, true)
      |> Map.put(
        :last_error,
        problem("asset-metadata-conflict", "Stored artifact metadata conflicts")
      )
      |> State.bump()

    case Persistence.save(degraded) do
      :ok -> {:error, :asset_metadata_conflict, degraded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_asset_size(profile, bytes) do
    byte_count = byte_size(bytes)

    cond do
      byte_count > profile["maximumAssetBytes"] -> {:error, :asset_too_large}
      exact_size(profile) not in [nil, byte_count] -> {:error, :invalid_dimensions}
      true -> :ok
    end
  end

  defp exact_size(
         %{"compression" => "none", "channelOrder" => order, "bitDepth" => bit_depth} = profile
       )
       when order in ["rgb", "bgr", "rgba", "bgra"] and is_integer(bit_depth) do
    channels = if order in ["rgb", "bgr"], do: 3, else: 4
    bytes_per_channel = div(bit_depth + 7, 8)
    profile["width"] * profile["height"] * channels * bytes_per_channel
  end

  defp exact_size(%{"channelOrder" => "palette-index", "bitDepth" => 4} = profile),
    do: div(profile["width"] * profile["height"], 2)

  defp exact_size(_), do: nil

  defp validate_packed_codes(
         capabilities,
         %{"channelOrder" => "palette-index", "bitDepth" => 4} = profile,
         bytes
       ) do
    with {:ok, codes} <- packed_codes(capabilities["color"], profile) do
      if packed_bytes_valid?(bytes, codes), do: :ok, else: {:error, :invalid_asset}
    end
  end

  defp validate_packed_codes(_, _, _), do: :ok

  defp packed_codes(
         %{"kind" => "restricted-palette", "palette" => palette, "profileRevision" => revision},
         %{
           "packing" => "indexed4-msb-row-major-v1",
           "compression" => "none",
           "rowAlignment" => 1,
           "byteOrder" => "not-applicable",
           "colorProfileRevision" => revision,
           "width" => width
         }
       ) do
    codes = Enum.map(palette, & &1["wireCode"])

    if rem(width, 2) == 0 and length(codes) in 2..16 and
         length(Enum.uniq(codes)) == length(codes) and Enum.all?(codes, &(&1 in 0..15)),
       do: {:ok, codes},
       else: {:error, :unsupported_profile}
  end

  defp packed_codes(_, _), do: {:error, :unsupported_profile}

  defp packed_bytes_valid?(<<>>, _), do: true

  defp packed_bytes_valid?(<<left::4, right::4, rest::binary>>, codes),
    do: left in codes and right in codes and packed_bytes_valid?(rest, codes)

  defp ensure_storage(state, digest, byte_count) do
    storage = state.capabilities["storage"]
    summary = State.storage_summary(state)

    cond do
      Map.has_key?(state.assets, digest) -> :ok
      state.faults[:storage_full] -> {:error, :storage_full}
      map_size(state.assets) >= storage["maximumAssetCount"] -> {:error, :storage_full}
      byte_count > storage["maximumAssetBytes"] -> {:error, :asset_too_large}
      byte_count > summary["availableBytes"] -> {:error, :storage_full}
      true -> :ok
    end
  end

  defp commit_asset(state, digest, profile_id, byte_count, placement) do
    if Map.has_key?(state.assets, digest) do
      {:ok, :existing, state}
    else
      persist_new_asset(state, digest, profile_id, byte_count, placement)
    end
  end

  defp persist_new_asset(state, digest, profile_id, byte_count, placement) do
    {:ok, profile_digest} = Profile.digest(state.capabilities, profile_id)

    next_state =
      state
      |> Map.update!(
        :assets,
        &Map.put(&1, digest, %{
          "profileId" => profile_id,
          "byteCount" => byte_count,
          "profileDigest" => profile_digest
        })
      )
      |> State.bump()

    case Persistence.save(next_state) do
      :ok ->
        disposition = if placement == :existing, do: :existing, else: :created
        {:ok, disposition, next_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_asset_record(state, digest) do
    cond do
      not Map.has_key?(state.assets, digest) -> {:ok, state}
      protected_asset?(state, digest) -> {:error, :asset_referenced}
      true -> delete_unreferenced_asset(state, digest)
    end
  end

  defp protected_asset?(state, digest) do
    digest in [state.desired_asset, state.current_asset, state.previous_known_good] or
      Enum.any?(get_in(state.playlist || %{}, ["entries"]) || [], &(&1["assetDigest"] == digest))
  end

  defp delete_unreferenced_asset(state, digest) do
    next_state = state |> Map.update!(:assets, &Map.delete(&1, digest)) |> State.bump()

    case Persistence.save(next_state) do
      :ok ->
        case ContentStore.delete_active(state.data_dir, digest) do
          :ok -> {:ok, next_state}
          {:error, :enoent} -> {:ok, next_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp set_desired_record(state, request, precondition, suspend_playlist \\ false) do
    with :ok <- Schema.validate("desired", request),
         :ok <- validate_desired_asset(state, request),
         {:new, request_hash} <- request_status(state, request),
         :ok <- check_precondition(state, precondition) do
      accept_desired(state, request, request_hash, suspend_playlist)
    else
      {:repeat, _} -> {:ok, state}
      {:conflict, _} -> {:error, :request_id_conflict}
      {:error, reason} -> {:error, normalize_schema_error(reason)}
    end
  end

  defp validate_desired_asset(state, request) do
    cond do
      not Map.has_key?(state.assets, request["assetDigest"]) -> {:error, :asset_missing}
      asset_compatible?(state, request["assetDigest"], request["artifactProfile"]) -> :ok
      true -> {:error, :unsupported_profile}
    end
  end

  defp request_status(state, request) do
    request_hash = Digest.sha256(RFC8785.encode!(request))

    case state.requests[request["requestId"]] do
      nil -> {:new, request_hash}
      ^request_hash -> {:repeat, request_hash}
      _ -> {:conflict, request_hash}
    end
  end

  defp check_precondition(%{desired_asset: nil}, "*"), do: :ok

  defp check_precondition(state, precondition) do
    if precondition == State.etag(state), do: :ok, else: {:error, :state_precondition}
  end

  defp accept_desired(state, request, request_hash, suspend_playlist) do
    accepted =
      state
      |> Map.put(:desired_asset, request["assetDigest"])
      |> Map.put(:desired_profile, request["artifactProfile"])
      |> Map.put(:pending_request_id, request["requestId"])
      |> Map.put(:display_state, "preparing")
      |> Map.put(
        :playlist_suspended,
        state.playlist_suspended or (suspend_playlist and state.playlist != nil)
      )
      |> Map.put(:last_error, nil)
      |> Map.update!(:requests, &Map.put(&1, request["requestId"], request_hash))
      |> State.bump()

    with :ok <- Persistence.save(accepted) do
      if accepted.faults[:power_loss_at] == :after_desired,
        do: {:error, :power_loss, accepted},
        else: perform_display(accepted)
    end
  end

  defp perform_display(state) do
    if asset_compatible?(state, state.desired_asset, state.desired_profile),
      do: perform_compatible_display(state),
      else: {:error, :unsupported_profile, state}
  end

  defp retry_display_record(state) do
    if asset_compatible?(state, state.desired_asset, state.desired_profile) do
      preparing =
        state
        |> Map.put(:display_state, "preparing")
        |> Map.put(:last_error, nil)
        |> State.bump()

      case Persistence.save(preparing) do
        :ok -> perform_display(preparing)
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, :unsupported_profile, state}
    end
  end

  defp perform_compatible_display(state) do
    refreshing = state |> Map.put(:display_state, "refreshing") |> State.bump()

    case Persistence.save(refreshing) do
      :ok ->
        maybe_delay(refreshing.faults[:slow_refresh_ms])
        display_outcome(refreshing)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp display_outcome(%{faults: %{power_loss_at: checkpoint}} = state)
       when checkpoint in [:during_refresh, :after_refresh],
       do: {:error, :power_loss, state}

  defp display_outcome(%{faults: %{display_failure: true}} = state) do
    failed =
      state
      |> Map.put(:display_state, "failed")
      |> Map.put(:last_error, problem("display-failed", "Display adapter reported failure"))
      |> State.bump()

    case Persistence.save(failed) do
      :ok -> {:error, :display_failed, failed}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp display_outcome(state) do
    displayed =
      state
      |> Map.put(:previous_known_good, state.current_asset)
      |> Map.put(:current_asset, state.desired_asset)
      |> Map.put(:pending_request_id, nil)
      |> Map.put(:display_state, "displayed")
      |> Map.put(:last_error, nil)
      |> State.bump()

    case Persistence.save(displayed) do
      :ok -> {:ok, displayed}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp maybe_delay(nil), do: :ok
  defp maybe_delay(0), do: :ok
  defp maybe_delay(milliseconds), do: Process.sleep(milliseconds)

  defp set_playlist_record(%{playlist: playlist} = state, playlist, _)
       when is_map(playlist) do
    case validate_playlist_capabilities(state, playlist) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_playlist_record(state, playlist, precondition) do
    with :ok <- Schema.validate("playlist", playlist),
         :ok <- check_precondition(state, precondition),
         :ok <- validate_playlist_revision(playlist),
         :ok <- validate_playlist_capabilities(state, playlist) do
      next_state =
        state
        |> Map.put(:playlist, playlist)
        |> Map.put(:playlist_index, nil)
        |> Map.put(:playlist_due_ms, nil)
        |> Map.put(:playlist_clock_ms, nil)
        |> Map.put(:playlist_retry_at_ms, nil)
        |> Map.put(:playlist_suspended, false)
        |> State.bump()

      case Persistence.save(next_state) do
        :ok -> {:ok, next_state}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, normalize_schema_error(reason)}
    end
  end

  defp validate_playlist_revision(playlist) do
    payload = Map.take(playlist, ["mode", "entries"])

    if Digest.sha256(RFC8785.encode!(payload)) == playlist["revision"],
      do: :ok,
      else: {:error, :playlist_revision_mismatch}
  end

  defp advance_playlist_record(_, now_ms) when not is_integer(now_ms) or now_ms < 0,
    do: {:error, :invalid_clock}

  defp advance_playlist_record(%{playlist: nil}, _), do: {:error, :no_playlist}

  defp advance_playlist_record(%{playlist_suspended: true} = state, _),
    do: {:ok, :suspended, state}

  defp advance_playlist_record(%{playlist_clock_ms: prior} = state, now_ms)
       when is_integer(prior) and now_ms < prior,
       do: {:error, :clock_regressed, state}

  defp advance_playlist_record(state, now_ms) do
    case next_playlist_index(state, now_ms) do
      :waiting -> {:ok, :waiting, state}
      index -> advance_playlist_entry(state, index, now_ms)
    end
  end

  defp next_playlist_index(%{playlist_retry_at_ms: retry_at}, now_ms)
       when is_integer(retry_at) and now_ms < retry_at,
       do: :waiting

  defp next_playlist_index(%{playlist_index: nil}, _), do: 0

  defp next_playlist_index(%{playlist: %{"mode" => "hold"}}, _), do: :waiting

  defp next_playlist_index(%{playlist_due_ms: due}, now_ms)
       when is_integer(due) and now_ms < due,
       do: :waiting

  defp next_playlist_index(state, _) do
    rem(state.playlist_index + 1, length(state.playlist["entries"]))
  end

  defp advance_playlist_entry(state, index, now_ms) do
    entry = Enum.at(state.playlist["entries"], index)
    digest = entry["assetDigest"]

    cond do
      not asset_compatible?(state, digest, get_in(state.assets, [digest, "profileId"])) ->
        {:error, :unsupported_profile, state}

      state.current_asset == digest and state.display_state == "displayed" ->
        complete_playlist_entry(state, index, now_ms)

      state.desired_asset == digest ->
        finish_playlist_display(perform_display(state), index, now_ms)

      true ->
        request_playlist_display(state, index, digest, now_ms)
    end
  end

  defp request_playlist_display(state, index, digest, now_ms) do
    profile_id = state.assets[digest]["profileId"]
    revision = state.playlist["revision"] |> String.replace_prefix("sha256:", "")
    request_id = "playlist-#{String.slice(revision, 0, 16)}-#{index}-#{now_ms}"

    request = %{
      "assetDigest" => digest,
      "artifactProfile" => profile_id,
      "requestId" => request_id
    }

    state
    |> set_desired_record(request, State.etag(state))
    |> finish_playlist_display(index, now_ms)
  end

  defp finish_playlist_display({:ok, displayed}, index, now_ms),
    do: complete_playlist_entry(displayed, index, now_ms)

  defp finish_playlist_display({:error, :display_failed, failed}, _, now_ms) do
    minimum = failed.capabilities["refresh"]["minimumDwellMs"]

    retrying =
      failed
      |> Map.put(:playlist_retry_at_ms, now_ms + minimum)
      |> Map.put(:playlist_clock_ms, now_ms)
      |> State.bump()

    case Persistence.save(retrying) do
      :ok -> {:error, :display_failed, retrying}
      {:error, reason} -> {:error, reason, failed}
    end
  end

  defp finish_playlist_display({:error, reason, state}, _, _),
    do: {:error, reason, state}

  defp finish_playlist_display({:error, reason}, _, _), do: {:error, reason}

  defp complete_playlist_entry(state, index, now_ms) do
    completion_ms = now_ms + Map.get(state.faults, :slow_refresh_ms, 0)
    entry = Enum.at(state.playlist["entries"], index)

    due_ms =
      if state.playlist["mode"] == "cycle",
        do: completion_ms + entry["dwellMs"],
        else: nil

    completed =
      state
      |> Map.put(:playlist_index, index)
      |> Map.put(:playlist_due_ms, due_ms)
      |> Map.put(:playlist_clock_ms, completion_ms)
      |> Map.put(:playlist_retry_at_ms, nil)
      |> State.bump()

    case Persistence.save(completed) do
      :ok -> {:ok, State.public(completed), completed}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp pull_outbox_record(%{faults: %{missed_contact: true}}, _, _),
    do: {:error, :contact_missed}

  defp pull_outbox_record(state, manifest, bytes) when is_binary(bytes) do
    case Schema.validate("outbox-manifest", manifest) do
      :ok -> receive_outbox_manifest(state, manifest, bytes)
      {:error, reason} -> {:error, normalize_schema_error(reason)}
    end
  end

  defp pull_outbox_record(state, manifest, nil) do
    case Schema.validate("outbox-manifest", manifest) do
      :ok -> receive_outbox_manifest(state, manifest, nil)
      {:error, reason} -> {:error, normalize_schema_error(reason)}
    end
  end

  defp pull_outbox_record(_, _, _), do: {:error, :invalid_document}

  defp receive_outbox_manifest(state, %{"desiredAsset" => nil}, _),
    do: {:ok, :no_work, state}

  defp receive_outbox_manifest(
         %{
           current_asset: digest,
           desired_profile: profile_id,
           display_state: "displayed"
         } = state,
         %{"desiredAsset" => digest, "artifactProfile" => profile_id} = manifest,
         _
       )
       when is_binary(digest) do
    if asset_compatible?(state, digest, profile_id),
      do: outbox_acknowledgement(manifest, :existing, "displayed", state),
      else: {:error, :unsupported_profile, state}
  end

  defp receive_outbox_manifest(state, manifest, bytes),
    do: receive_outbox_asset(state, manifest, bytes)

  defp receive_outbox_asset(state, manifest, bytes) do
    digest = manifest["desiredAsset"]
    profile_id = manifest["artifactProfile"]

    installation =
      case bytes do
        nil ->
          if asset_compatible?(state, digest, profile_id),
            do: {:ok, :existing, state},
            else: {:error, :asset_missing}

        _ ->
          put_asset_record(state, digest, profile_id, bytes)
      end

    case installation do
      {:ok, disposition, uploaded} -> activate_outbox_asset(uploaded, manifest, disposition)
      {:error, reason, next_state} -> {:error, reason, next_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp activate_outbox_asset(state, manifest, disposition) do
    request = %{
      "assetDigest" => manifest["desiredAsset"],
      "artifactProfile" => manifest["artifactProfile"],
      "requestId" => "outbox-#{manifest["revision"]}"
    }

    precondition = if state.desired_asset == nil, do: "*", else: State.etag(state)

    case set_desired_record(state, request, precondition, true) do
      {:ok, next_state} ->
        complete_outbox_display(next_state, manifest, disposition)

      {:error, :display_failed, failed} ->
        outbox_acknowledgement(manifest, disposition, "failed", failed)

      {:error, reason, next_state} ->
        {:error, reason, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp complete_outbox_display(state, manifest, disposition) do
    cond do
      not asset_compatible?(state, manifest["desiredAsset"], manifest["artifactProfile"]) ->
        {:error, :unsupported_profile, state}

      state.current_asset == manifest["desiredAsset"] and state.display_state == "displayed" ->
        outbox_acknowledgement(manifest, disposition, "displayed", state)

      state.desired_asset == manifest["desiredAsset"] ->
        resume_outbox_display(state, manifest, disposition)

      true ->
        {:error, :manifest_superseded, state}
    end
  end

  defp resume_outbox_display(state, manifest, disposition) do
    case perform_display(state) do
      {:ok, displayed} ->
        outbox_acknowledgement(manifest, disposition, "displayed", displayed)

      {:error, :display_failed, failed} ->
        outbox_acknowledgement(manifest, disposition, "failed", failed)

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp outbox_acknowledgement(manifest, disposition, refresh, state) do
    acknowledgement = %{
      "manifestRevision" => manifest["revision"],
      "storage" => if(disposition == :existing, do: "unchanged", else: "verified"),
      "refresh" => refresh,
      "currentAsset" => state.current_asset,
      "lastError" => state.last_error
    }

    case Schema.validate("outbox-ack", acknowledgement) do
      :ok -> {:ok, acknowledgement, state}
      {:error, reason} -> {:error, normalize_schema_error(reason), state}
    end
  end

  defp validate_playlist_capabilities(state, playlist) do
    storage = state.capabilities["storage"]
    minimum_dwell = state.capabilities["refresh"]["minimumDwellMs"]

    cond do
      length(playlist["entries"]) > storage["maximumPlaylistLength"] ->
        {:error, :playlist_too_long}

      Enum.any?(playlist["entries"], &(&1["dwellMs"] < minimum_dwell)) ->
        {:error, :dwell_too_short}

      Enum.any?(playlist["entries"], &(not Map.has_key?(state.assets, &1["assetDigest"]))) ->
        {:error, :asset_missing}

      Enum.any?(playlist["entries"], fn entry ->
        digest = entry["assetDigest"]
        not asset_compatible?(state, digest, get_in(state.assets, [digest, "profileId"]))
      end) ->
        {:error, :unsupported_profile}

      true ->
        :ok
    end
  end

  defp normalize_schema_error(%JSV.ValidationError{}), do: :invalid_document
  defp normalize_schema_error(reason), do: reason

  defp problem(type, title) do
    %{"type" => "urn:frameshift:problem:#{type}", "title" => title}
  end
end
