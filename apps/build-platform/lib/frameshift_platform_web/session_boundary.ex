defmodule FrameshiftPlatformWeb.SessionBoundary do
  @moduledoc """
  Installs the encrypted browser session and its request protection boundary.

  The session routes alone fetch the signed/encrypted HttpOnly cookie with a
  12-hour maximum age, SameSite Strict and Path `/`. Production defaults to Secure;
  only explicit loopback development/test configuration disables that flag.
  Session cookie input over 4096 bytes refuses before decryption. Public catalog
  routes do not load account state or acquire a session cookie.

  ## Request and response protection

  Writes require exactly one Origin from the endpoint's configured exact list
  and `Plug.CSRFProtection` verification. Forwarded headers, query parameters and
  browser role claims do not establish authority. Refusals return finite JSON
  with 403, without dispatching a credential or revocation action. All session
  responses carry `no-store`, `nosniff` and a no-referrer policy. Authentication
  tokens remain inside cookie custody and never enter the response projection.
  """

  import Plug.Conn
  @behaviour Plug

  @session Plug.Session.init(
             store: :cookie,
             key: "_frameshift_session",
             signing_salt: "frameshift-session-signing-v1",
             encryption_salt: "frameshift-session-encryption-v1",
             max_age: 43_200,
             http_only: true,
             same_site: "Strict",
             path: "/",
             log: false,
             secure: Application.compile_env(:frameshift_platform, :secure_session_cookie, true)
           )
  @csrf Plug.CSRFProtection.init([])

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> fetch_cookies()

    cookie = conn.req_cookies["_frameshift_session"]

    cond do
      is_binary(cookie) and byte_size(cookie) > 4096 ->
        refuse(conn, 400, "invalid_session")

      conn.method not in ["GET", "HEAD"] and not origin?(conn) ->
        refuse(conn, 403, "forbidden")

      true ->
        conn |> Plug.Session.call(@session) |> fetch_session() |> Plug.CSRFProtection.call(@csrf)
    end
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError -> refuse(conn, 403, "forbidden")
  end

  defp origin?(conn) do
    allowed = FrameshiftPlatformWeb.Endpoint.config(:check_origin)

    case get_req_header(conn, "origin") do
      [origin] when is_list(allowed) -> origin in allowed
      _ -> false
    end
  end

  defp refuse(conn, status, reason),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: reason}))
      |> halt()
end
