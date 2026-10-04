defmodule Frameshift.DisplayTiming do
  @moduledoc """
  Applies receiver dwell limits and source-qualified playlist recommendations.

  The receiver's `minimumDwellMs` is a hard limit. Optional recommended dwell
  includes a basis and revision and must not fall below that minimum.
  `validate_refresh/1` checks the cross-field relation after structural admission;
  `recommendation/1` returns the complete suggestion or `nil` if absent.

  ## Choosing an interval

  `clamp_dwell/2` applies the shared pure decision kernel to an explicitly supplied
  positive interval and the receiver minimum. `Frameshift.Playlist.Plan` uses
  these rules when choosing an override or profile suggestion. No interval is
  inferred from a vendor name, frame class or an assumed e-paper refresh period.

  These functions inspect already admitted capability data and perform no clock,
  network or persistence I/O. A source recommendation remains advisory; receiver
  limits and actual physical timing evidence have separate authority.
  """

  @type recommendation :: %{
          dwell_ms: pos_integer(),
          basis: String.t(),
          revision: String.t()
        }

  @doc "Checks the semantic bound that JSON Schema cannot compare across fields."
  @spec validate_refresh(map()) :: :ok | {:error, :recommendation_below_minimum}
  def validate_refresh(%{"minimumDwellMs" => minimum} = refresh) do
    case Map.fetch(refresh, "recommendedDwellMs") do
      {:ok, dwell} when dwell < minimum -> {:error, :recommendation_below_minimum}
      _ -> :ok
    end
  end

  @doc "Returns the optional profile suggestion with its provenance."
  @spec recommendation(map()) :: recommendation() | nil
  def recommendation(%{"refresh" => refresh}) do
    case refresh do
      %{
        "recommendedDwellMs" => dwell,
        "recommendationBasis" => basis,
        "recommendationRevision" => revision
      } ->
        %{dwell_ms: dwell, basis: basis, revision: revision}

      _ ->
        nil
    end
  end

  @doc "Clamps an operator's dwell to the receiver's current minimum."
  @spec clamp_dwell(map(), pos_integer()) :: pos_integer()
  def clamp_dwell(%{"refresh" => %{"minimumDwellMs" => minimum}}, requested)
      when is_integer(requested) and requested > 0 do
    case :frameshift_decisions.select_dwell(minimum, requested) do
      {:ok, dwell} -> dwell
      {:error, :invalid_input} -> raise ArgumentError, "invalid dwell interval"
    end
  end
end
