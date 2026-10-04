defmodule FrameshiftPlatformWeb.PageController do
  @moduledoc """
  Serves the built SvelteKit application's HTML with matching script policy.

  `show/2` reads `priv/static/index.html` from the installed platform application.
  The response computes SHA-256 allowances from that HTML's inline script bodies,
  sets a same-origin content security policy and disables stale HTML caching.
  Static application assets are served separately by the endpoint.

  ## Build and failure behavior

  The controller never invokes a frontend compiler or fetches assets remotely.
  A missing/unreadable index returns 503 with a public availability message.
  The installed HTML and hashed assets must therefore come from the same qualified
  asset build; a running endpoint alone does not establish that the UI is present.
  """

  use Phoenix.Controller, formats: [:html]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _) do
    path = Application.app_dir(:frameshift_platform, "priv/static/index.html")

    case File.read(path) do
      {:ok, html} ->
        serve(conn, html)

      {:error, _} ->
        conn |> put_status(503) |> text("The configuration site is temporarily unavailable.")
    end
  end

  defp serve(conn, html) do
    hashes =
      Regex.scan(~r/<script\b[^>]*>(.*?)<\/script>/s, html, capture: :all_but_first)
      |> Enum.map_join(" ", fn [script] ->
        "'sha256-#{Base.encode64(:crypto.hash(:sha256, script))}'"
      end)

    policy =
      "default-src 'self'; script-src 'self' #{hashes}; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"

    conn
    |> put_resp_header("content-security-policy", policy)
    |> put_resp_header("cache-control", "no-cache")
    |> html(html)
  end
end
