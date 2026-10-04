defmodule Frameshift.Simulator.State do
  @moduledoc """
  Represents persistent artwork state and transient simulator dependencies.

  The struct requires capabilities and data directory, and keeps desired/current/
  previous-known-good assets, request identity, display errors, verified asset
  metadata and playlist timing as distinct fields. `bump/1` advances the state
  revision and `etag/1` derives the corresponding strong reference ETag.

  ## Stored and public projections

  `persisted/1` selects artwork/playlist fields for checksummed disk records;
  `from_persisted/3` restores those fields with explicitly supplied capabilities
  and root. `public/1` exposes protocol state and bounded storage summary rather
  than transient faults, secret pairing state or injected Thing source.

  Desired and current must not be collapsed: verified bytes can exist while
  physical activation is interrupted. This struct performs no transition,
  authentication or I/O; `Frameshift.Simulator` and its separate persistence and
  pairing owners decide those behaviors.
  """

  @enforce_keys [:capabilities, :data_dir]
  defstruct capabilities: nil,
            data_dir: nil,
            revision: 0,
            display_state: "empty",
            desired_asset: nil,
            desired_profile: nil,
            current_asset: nil,
            previous_known_good: nil,
            pending_request_id: nil,
            last_error: nil,
            assets: %{},
            requests: %{},
            playlist: nil,
            playlist_index: nil,
            playlist_due_ms: nil,
            playlist_clock_ms: nil,
            playlist_retry_at_ms: nil,
            playlist_suspended: false,
            pairing: nil,
            thing_source: nil,
            faults: %{}

  @type t :: %__MODULE__{}

  @spec new(map(), String.t()) :: t()
  def new(capabilities, data_dir), do: %__MODULE__{capabilities: capabilities, data_dir: data_dir}

  @spec from_persisted(map(), map(), String.t()) :: t()
  def from_persisted(payload, capabilities, data_dir) do
    %__MODULE__{
      capabilities: capabilities,
      data_dir: data_dir,
      revision: payload["stateRevision"],
      display_state: payload["displayState"],
      desired_asset: payload["desiredAsset"],
      desired_profile: payload["desiredProfile"],
      current_asset: payload["currentAsset"],
      previous_known_good: payload["previousKnownGood"],
      pending_request_id: payload["pendingRequestId"],
      last_error: payload["lastError"],
      assets: payload["assets"] || %{},
      requests: payload["requests"] || %{},
      playlist: payload["playlist"],
      playlist_index: payload["playlistIndex"],
      playlist_due_ms: payload["playlistDueMs"],
      playlist_clock_ms: payload["playlistClockMs"],
      playlist_retry_at_ms: payload["playlistRetryAtMs"],
      playlist_suspended: payload["playlistSuspended"] || false
    }
  end

  @spec persisted(t()) :: map()
  def persisted(state) do
    %{
      "stateRevision" => state.revision,
      "displayState" => state.display_state,
      "desiredAsset" => state.desired_asset,
      "desiredProfile" => state.desired_profile,
      "currentAsset" => state.current_asset,
      "previousKnownGood" => state.previous_known_good,
      "pendingRequestId" => state.pending_request_id,
      "lastError" => state.last_error,
      "assets" => state.assets,
      "requests" => state.requests,
      "playlist" => state.playlist,
      "playlistIndex" => state.playlist_index,
      "playlistDueMs" => state.playlist_due_ms,
      "playlistClockMs" => state.playlist_clock_ms,
      "playlistRetryAtMs" => state.playlist_retry_at_ms,
      "playlistSuspended" => state.playlist_suspended
    }
  end

  @spec public(t()) :: map()
  def public(state) do
    %{
      "stateRevision" => state.revision,
      "displayState" => state.display_state,
      "desiredAsset" => state.desired_asset,
      "currentAsset" => state.current_asset,
      "previousKnownGood" => state.previous_known_good,
      "pendingRequestId" => state.pending_request_id,
      "lastError" => state.last_error,
      "storage" => storage_summary(state),
      "playlist" => state.playlist,
      "playlistIndex" => state.playlist_index,
      "playlistDueMs" => state.playlist_due_ms,
      "playlistRetryAtMs" => state.playlist_retry_at_ms,
      "playlistSuspended" => state.playlist_suspended
    }
  end

  @spec etag(t()) :: String.t()
  def etag(state), do: ~s("fs-state-#{state.revision}")

  @spec storage_summary(t()) :: map()
  def storage_summary(state) do
    storage = state.capabilities["storage"]
    used = state.assets |> Map.values() |> Enum.sum_by(& &1["byteCount"])

    %{
      "assetCount" => map_size(state.assets),
      "usedBytes" => used,
      "availableBytes" => max(storage["totalBytes"] - used, 0)
    }
  end

  @spec bump(t()) :: t()
  def bump(state), do: %{state | revision: state.revision + 1}
end
