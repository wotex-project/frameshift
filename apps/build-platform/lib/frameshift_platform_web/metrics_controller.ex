defmodule FrameshiftPlatformWeb.MetricsController do
  @moduledoc """
  Serves the protected platform Prometheus scrape endpoint.

  `show/2` requires exactly one bearer authorization value matching the configured
  `:metrics_token`, which must contain at least 32 bytes. Comparison uses hashed
  values and constant-time comparison. Missing or invalid authorization returns
  401; responses always carry `cache-control: no-store`.

  ## Collector availability

  An authorized request exports `FrameshiftPlatform.Telemetry.Reporter` text.
  A missing or failed reporter returns 503 rather than an empty successful scrape.
  This endpoint supplies observations only: it does not enable model diagnostics,
  modify domain records or substitute metric counters for durable audit evidence.
  """

  use Phoenix.Controller, formats: [:text]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    token = Application.get_env(:frameshift_platform, :metrics_token)

    if authorized?(get_req_header(conn, "authorization"), token) do
      export(conn)
    else
      send_resp(conn, 401, "Unauthorized")
    end
  end

  defp export(conn) do
    case FrameshiftPlatform.Telemetry.Reporter.scrape() do
      {:ok, body} -> conn |> put_resp_content_type("text/plain", "utf-8") |> send_resp(200, body)
      {:error, :unavailable} -> send_resp(conn, 503, "Metrics unavailable")
    end
  end

  defp authorized?(["Bearer " <> supplied], token)
       when is_binary(token) and byte_size(token) >= 32 do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, supplied), :crypto.hash(:sha256, token))
  end

  defp authorized?(_, _), do: false
end
