defmodule Frameshift.Playlist.Plan do
  @moduledoc """
  Builds an exact still-image cycle from already rendered artifact identities.

  `build/3` validates the ordered artifact list against admitted frame capabilities
  and selects a dwell interval. The complete entry list and mode are canonically
  hashed into the playlist revision; reordering assets or changing dwell changes
  that revision. No live library or network state is consulted.

  ## Interval and installation

  `resolve_dwell/2` uses an explicit operator interval or a complete source-qualified
  profile recommendation. Without either it refuses; receiver minimums remain
  hard limits through `Frameshift.DisplayTiming`. A library pin is not itself an
  active playlist or permission to fabricate a default interval.

  The host must retain/render all artifacts before queueing the complete plan.
  `Frameshift.Playlist.Store` owns durable pending/active references and receiver
  acknowledgement. This module creates still-image intent, not motion/video or
  proof that the receiver installed and displayed a cycle.
  """

  alias Frameshift.Digest
  alias Frameshift.DisplayTiming

  @maximum_dwell_ms 31_536_000_000

  @type plan :: %{
          playlist: map(),
          dwell_ms: pos_integer(),
          source: :profile | :override,
          recommendation_revision: String.t() | nil
        }

  @doc "Constructs one canonical cycle, requiring an explicit dwell without a profile suggestion."
  @spec build(map(), [String.t()], pos_integer() | nil) :: {:ok, plan()} | {:error, atom()}
  def build(capabilities, artifact_digests, requested_dwell \\ nil) do
    with :ok <- validate_artifacts(capabilities, artifact_digests),
         {:ok, dwell, source, revision} <- resolve_dwell(capabilities, requested_dwell) do
      entries =
        Enum.map(artifact_digests, &%{"assetDigest" => &1, "dwellMs" => dwell})

      payload = %{"mode" => "cycle", "entries" => entries}
      playlist = Map.put(payload, "revision", Digest.sha256(RFC8785.encode!(payload)))

      {:ok,
       %{
         playlist: playlist,
         dwell_ms: dwell,
         source: source,
         recommendation_revision: revision
       }}
    end
  end

  defp validate_artifacts(%{"storage" => %{"maximumPlaylistLength" => maximum}}, digests)
       when is_list(digests) do
    cond do
      digests == [] -> {:error, :empty_playlist}
      length(digests) > maximum -> {:error, :playlist_too_long}
      length(Enum.uniq(digests)) != length(digests) -> {:error, :duplicate_artifact}
      not Enum.all?(digests, &Digest.valid_sha256?/1) -> {:error, :invalid_artifact}
      true -> :ok
    end
  end

  defp validate_artifacts(_, _), do: {:error, :invalid_artifact}

  @doc "Resolves an operator interval or the profile suggestion before rendering."
  @spec resolve_dwell(map(), pos_integer() | nil) ::
          {:ok, pos_integer(), :profile | :override, String.t() | nil} | {:error, atom()}
  def resolve_dwell(capabilities, nil) do
    case DisplayTiming.recommendation(capabilities) do
      nil -> {:error, :interval_required}
      %{dwell_ms: dwell, revision: revision} -> {:ok, dwell, :profile, revision}
    end
  end

  def resolve_dwell(capabilities, dwell)
      when is_integer(dwell) and dwell > 0 and dwell <= @maximum_dwell_ms do
    clamped = DisplayTiming.clamp_dwell(capabilities, dwell)
    {:ok, clamped, :override, nil}
  end

  def resolve_dwell(_, _), do: {:error, :invalid_interval}
end
