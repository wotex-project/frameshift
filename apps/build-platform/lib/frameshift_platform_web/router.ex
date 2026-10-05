defmodule FrameshiftPlatformWeb.Router do
  @moduledoc """
  Defines the platform's public catalog, protected session, UI and metrics routes.

  The JSON API exposes `/api/health`, `/api/sources`, `/api/profiles` and an
  exact-profile download route. `/api/composition/:class` reports the qualified
  consumer-profile boundary. `/` serves the installed Svelte application;
  `/ops/metrics` delegates authorization to the metrics controller. Catalog reads
  require no account and expose only their explicit public projections.
  `/api/session` GET/POST/DELETE owns current session, bounded sign-in and verified
  logout through `FrameshiftPlatformWeb.SessionBoundary`. There is no account
  registration, recovery or role-assignment route.

  ## Authority boundary

  There are no mutating catalog, composition, purchasing or device routes here.
  A session grants no catalog, composition or operator role. Adding a domain
  write endpoint requires a current server membership and resource policy,
  independently of the deliberately public API pipeline.
  Endpoint parsing and request-size limits apply before route dispatch.
  """

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :session do
    plug :accepts, ["json"]
    plug FrameshiftPlatformWeb.SessionBoundary
  end

  scope "/api", FrameshiftPlatformWeb do
    pipe_through :api
    get "/health", HealthController, :show
    get "/sources", SourceController, :index
    get "/profiles", ProfileController, :index
    get "/profiles/:digest", ProfileController, :show
    get "/composition/:class", CompositionController, :show
  end

  scope "/api", FrameshiftPlatformWeb do
    pipe_through :session
    get "/session", SessionController, :show
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete
  end

  get "/ops/metrics", FrameshiftPlatformWeb.MetricsController, :show
  get "/", FrameshiftPlatformWeb.PageController, :show
end
