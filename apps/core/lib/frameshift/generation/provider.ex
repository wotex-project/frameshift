defmodule Frameshift.Generation.Provider do
  @moduledoc """
  Defines the adapter contract for an explicitly selected still-image provider.

  Implement `c:id/0`, `c:preflight/1` and `c:generate/2`. Preflight identifies the
  provider/model, local or cloud destination, supported capabilities and required
  disclosures. Generation returns still bytes, dimensions, media type and the
  provider's result identifier, or an explicit error.

  ## Coordinator relationship

  `Frameshift.Generation` validates requests and results, owns canonical cache
  lookup and runs the selected adapter under a deadline. An adapter must not
  silently substitute providers or destinations when preflight fails.

  `t:context/0` may hold credentials or process handles and is transient;
  the coordinator does not persist or log it. Persisted request/result provenance
  must describe reproducibility and source lineage without embedding secrets.
  The callback contract does not authorize frame delivery or physical acceptance.
  """

  @type request :: map()
  @type context :: term()
  @type result :: %{
          required(:bytes) => binary(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:media_type) => String.t(),
          required(:result_id) => String.t()
        }
  @type preflight :: %{
          required(:provider_id) => String.t(),
          required(:model) => String.t(),
          required(:destination) => :local | :cloud,
          required(:capabilities) => map(),
          required(:disclosures) => map()
        }

  @callback id() :: String.t()
  @callback preflight(context()) :: {:ok, preflight()} | {:error, term()}
  @callback generate(request(), context()) :: {:ok, result()} | {:error, term()}
end
