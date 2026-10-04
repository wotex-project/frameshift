defmodule FrameshiftPlatformWeb.Endpoint do
  @moduledoc """
  Hosts bounded catalog HTTP requests and the companion application's assets.

  The endpoint assigns request IDs, emits platform-owned request telemetry and
  serves only the configured `_app` and favicon static paths. JSON parsing uses
  Jason with a 256 KiB request limit before routing through
  `FrameshiftPlatformWeb.Router`. No session or authenticated write pipeline is
  installed by these plugs.

  ## Response owners

  Catalog controllers expose explicit public projections, while the metrics
  controller checks its own bearer token. Static application HTML is served by
  `FrameshiftPlatformWeb.PageController` with a content security policy derived
  from the actual build. Configure endpoint startup through the platform host.
  """

  use Phoenix.Endpoint, otp_app: :frameshift_platform

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:frameshift_platform, :endpoint]
  plug Plug.Static, at: "/", from: :frameshift_platform, gzip: true, only: ~w(_app favicon.svg)

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 262_144

  plug Plug.MethodOverride
  plug Plug.Head
  plug FrameshiftPlatformWeb.Router
end
