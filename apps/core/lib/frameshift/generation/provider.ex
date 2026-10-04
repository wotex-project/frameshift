defmodule Frameshift.Generation.Provider do
  @moduledoc """
  Defines the adapter contract for an explicitly selected still-image provider.

  Implement `c:id/0`, `c:preflight/1` and `c:generate/2`. Preflight identifies the
  provider/model, local or cloud destination, supported capabilities and required
  disclosures. Generation returns exact original still bytes, platform-decoded
  canonical RGBA8, dimensions, media type, decoder identity/revision and the
  provider's result identifier, or an explicit error. Preflight matches exact
  model and decoder revisions; a mutable model alias is not a revision.

  ## Coordinator relationship

  `Frameshift.Generation` validates requests and results, owns canonical cache
  lookup and runs the selected adapter under a deadline. An adapter must not
  silently substitute providers or destinations when preflight fails.

  In edit mode the coordinator attaches `:source_image` to the provider request
  from an active verified master package. Its original bytes and canonical pixels
  are transient inputs, excluded from recipes and logs. The adapter owns actual
  platform decoding and must refuse unsupported or animated source containers;
  canonical-result fixtures alone do not qualify that codec or a live model.

  `t:context/0` may hold credentials or process handles and is transient;
  the coordinator does not persist or log it. Persisted request/result provenance
  must describe reproducibility and source lineage without embedding secrets.
  The callback contract does not authorize frame delivery or physical acceptance.
  """

  @type request :: map()
  @type context :: term()
  @type result :: %{
          required(:bytes) => binary(),
          required(:canonical_rgba) => binary(),
          required(:canonical_representation) => String.t(),
          required(:decoder_id) => String.t(),
          required(:decoder_revision) => String.t(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:media_type) => String.t(),
          required(:result_id) => String.t()
        }
  @type preflight :: %{
          required(:provider_id) => String.t(),
          required(:model) => String.t(),
          required(:model_revision) => String.t(),
          required(:decoder_id) => String.t(),
          required(:decoder_revision) => String.t(),
          required(:destination) => :local | :cloud,
          required(:capabilities) => map(),
          required(:disclosures) => map()
        }

  @callback id() :: String.t()
  @callback preflight(context()) :: {:ok, preflight()} | {:error, term()}
  @callback generate(request(), context()) :: {:ok, result()} | {:error, term()}
end
