defmodule FrameshiftPlatformWeb.HealthController do
  @moduledoc """
  Reports that the public endpoint can respond to a liveness request.

  `show/2` returns JSON with `status: "ok"` without querying PostgreSQL, Refpath,
  external providers or frame devices. The route requires no account and exposes
  no configuration, customer data or infrastructure details.

  ## Interpreting liveness

  A successful response establishes endpoint liveness only. Use
  `FrameshiftPlatform.Orchestration.readiness/0` for the configured producer boot
  probe and the separate metrics endpoint for collector observations. Neither
  liveness nor a readiness label establishes a qualified product integration.
  """

  use Phoenix.Controller, formats: [:json]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _), do: json(conn, %{status: "ok"})
end
