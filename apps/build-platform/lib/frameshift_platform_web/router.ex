defmodule FrameshiftPlatformWeb.Router do
  @moduledoc """
  Defines the platform's public catalog, liveness, UI and metrics routes.

  The JSON API exposes `/api/health`, `/api/sources`, `/api/profiles` and an
  exact-profile download route. `/api/composition/:class` reports the qualified
  consumer-profile boundary. `/` serves the installed Svelte application;
  `/ops/metrics` delegates authorization to the metrics controller. Catalog reads
  require no account and expose only their explicit public projections.

  ## Authority boundary

  There are no mutating catalog, composition, purchasing or device routes here.
  Adding a write endpoint requires an authenticated actor boundary and resource
  policies, rather than treating the current public API pipeline as a session.
  Endpoint parsing and request-size limits apply before route dispatch.
  """

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", FrameshiftPlatformWeb do
    pipe_through :api
    get "/health", HealthController, :show
    get "/sources", SourceController, :index
    get "/profiles", ProfileController, :index
    get "/profiles/:digest", ProfileController, :show
    get "/composition/:class", CompositionController, :show
  end

  get "/ops/metrics", FrameshiftPlatformWeb.MetricsController, :show
  get "/", FrameshiftPlatformWeb.PageController, :show
end
