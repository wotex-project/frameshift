defmodule FrameshiftPlatform.Composition do
  @moduledoc """
  Reports the consumer qualification boundary for frame composition.

  Paper, Photo and Pixel require every retained frame obligation before their
  successor Conjunct profile can be offered. `availability/1` reports that
  boundary independently of catalog completeness, kernel transport readiness
  and physical evidence. A successfully loaded component or an upstream sample
  does not qualify a complete frame profile.

  ## Current profile

  The pinned producer supplies typed comparisons, sums, interface checks and
  geometry assessments. Directed network flow, shared contract intersection,
  support-path aggregation and controller route resolution still need a
  producer contract and reproducing consumer fixtures. Candidate mappings for
  the remaining obligations also need full positive/violated/unknown acceptance.
  Consequently every frame class reports `unavailable`; callers cannot supply
  a readiness flag, omit an obligation or promote synthetic results.

  ## Authority and recovery

  This module reads no customer data and starts no worker, database transaction
  or external effect. The public projection is deterministic across restart.
  Existing v1 bytes and compiler replay remain owned by `FrameshiftBuild`.
  Replace this refusal only with the complete S2/S3 evidence required by the
  Conjunct integration contract; transport qualification alone is insufficient.
  """

  @classes ~w(paper photo pixel)
  @stages ~w(graph completeness geometry viewing power_interfaces power_loads power_contracts thermal mounting signals signal_routes operation artifacts)
  @producer_gaps ~w(graph viewing power_loads power_contracts mounting signals signal_routes artifacts)
  @revision "f6609c5e4c2188626f5e1f345446fec04e78d6c9"

  @type availability :: %{
          class: String.t(),
          status: :unavailable,
          reason: :producer_profile_incomplete,
          producer_revision: String.t(),
          mandatory_obligations: [String.t()],
          producer_gaps: [String.t()],
          admission: false
        }

  @doc "Return the complete frame-profile refusal for one exact supported class."
  @spec availability(term()) :: {:ok, availability()} | {:error, :unsupported_class}
  def availability(class) when class in @classes do
    {:ok,
     %{
       class: class,
       status: :unavailable,
       reason: :producer_profile_incomplete,
       producer_revision: @revision,
       mandatory_obligations: @stages,
       producer_gaps: @producer_gaps,
       admission: false
     }}
  end

  def availability(_), do: {:error, :unsupported_class}
end
