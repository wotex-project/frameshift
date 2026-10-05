defmodule FrameshiftPlatformWeb.SessionHTTPTest do
  @moduledoc false

  use FrameshiftPlatform.DataCase, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import ExUnit.CaptureLog
  alias FrameshiftPlatform.Access.Authentication
  alias FrameshiftPlatform.Repo
  @endpoint FrameshiftPlatformWeb.Endpoint
  @password "a long fixture password 🔒"

  setup do
    ip = {127, 1, 0, :erlang.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}
    %{ip: ip}
  end

  test "anonymous session exposes CSRF only with bounded encrypted cookie policy" do
    conn = get(build_conn(), "/api/session")
    assert %{"authenticated" => false, "csrf_token" => csrf} = json_response(conn, 200)
    assert is_binary(csrf)
    cookie = conn.resp_cookies["_frameshift_session"]
    assert cookie.http_only
    assert cookie.same_site == "Strict"
    assert cookie.path == "/"
    assert cookie.max_age == 43_200
    refute cookie.secure
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert length(Map.keys(json_response(conn, 200))) == 2
    assert get(build_conn(), "/api/sources").resp_cookies == %{}
  end

  test "sign-in renews cookie and CSRF; logout revokes before clearing", %{ip: ip} do
    user = register()
    anonymous = get(build_conn(), "/api/session")
    csrf = json_response(anonymous, 200)["csrf_token"]
    conn = write(anonymous, :post, %{email: to_string(user.email), password: @password}, csrf, ip)
    assert %{"authenticated" => true, "csrf_token" => renewed_csrf} = json_response(conn, 200)
    refute renewed_csrf == csrf

    refute conn.resp_cookies["_frameshift_session"].value ==
             anonymous.resp_cookies["_frameshift_session"].value

    token = get_session(conn, "user_token")
    refute response(conn, 200) =~ token
    refute conn.resp_cookies["_frameshift_session"].value =~ token
    assert {:ok, _} = Authentication.authenticate(token)

    assert %{"authenticated" => false} =
             anonymous |> recycle() |> get("/api/session") |> json_response(200)

    assert %{"authenticated" => true} =
             conn |> recycle() |> get("/api/session") |> json_response(200)

    assert write(conn, :delete, %{}, csrf, ip) |> json_response(403) == %{"error" => "forbidden"}
    logged_out = write(conn, :delete, %{}, renewed_csrf, ip)
    assert %{"authenticated" => false} = json_response(logged_out, 200)
    assert {:error, :invalid_credentials} = Authentication.authenticate(token)

    assert %{"authenticated" => false} =
             logged_out |> recycle() |> get("/api/session") |> json_response(200)
  end

  test "missing, duplicate and unrelated origins or missing CSRF cannot dispatch credentials", %{
    ip: ip
  } do
    user = register()
    anonymous = get(build_conn(), "/api/session")
    csrf = json_response(anonymous, 200)["csrf_token"]
    body = Jason.encode!(%{email: to_string(user.email), password: @password})

    for headers <- [
          [],
          [{"origin", "null"}],
          [{"origin", "http://evil.example"}],
          [{"origin", "http://www.example.com"}, {"origin", "http://www.example.com"}]
        ] do
      conn =
        anonymous
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-csrf-token", csrf)

      conn = %{conn | remote_ip: ip, req_headers: headers ++ conn.req_headers}
      conn = post(conn, "/api/session", body)
      assert json_response(conn, 403) == %{"error" => "forbidden"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    assert write(
             anonymous,
             :post,
             %{email: to_string(user.email), password: @password},
             "invalid",
             ip
           )
           |> json_response(403) == %{"error" => "forbidden"}

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])
  end

  test "extra roles, query credentials and oversized inputs refuse without authentication", %{
    ip: ip
  } do
    anonymous = get(build_conn(), "/api/session")
    csrf = json_response(anonymous, 200)["csrf_token"]

    for body <- [
          %{email: "a@example.com", password: @password, role: "operator"},
          %{password: @password},
          %{email: "a@example.com", password: String.duplicate("a", 513)},
          %{email: ["a@example.com"], password: @password}
        ] do
      assert write(anonymous, :post, body, csrf, ip) |> json_response(400) == %{
               "error" => "invalid_input"
             }
    end

    conn =
      anonymous
      |> request(csrf, ip)
      |> post(
        "/api/session?email=a%40example.com",
        Jason.encode!(%{email: "a@example.com", password: @password})
      )

    assert json_response(conn, 400) == %{"error" => "invalid_input"}
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])
  end

  test "incorrect credential attempts share a finite error and reach the IP budget", %{ip: ip} do
    anonymous = get(build_conn(), "/api/session")
    csrf = json_response(anonymous, 200)["csrf_token"]

    for _ <- 1..6 do
      assert write(
               anonymous,
               :post,
               %{email: "missing@example.com", password: @password},
               csrf,
               ip
             )
             |> json_response(401) == %{"error" => "invalid_credentials"}
    end

    conn = write(anonymous, :post, %{email: "missing@example.com", password: @password}, csrf, ip)
    assert json_response(conn, 429) == %{"error" => "limited"}
    assert get_resp_header(conn, "retry-after") == ["60"]
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])
  end

  test "forged and oversized cookies never establish account state" do
    for value <- ["forged", String.duplicate("a", 4097)] do
      conn =
        build_conn()
        |> put_req_header("cookie", "_frameshift_session=" <> value)
        |> get("/api/session")

      if byte_size(value) > 4096 do
        assert json_response(conn, 400) == %{"error" => "invalid_session"}
      else
        assert %{"authenticated" => false} = json_response(conn, 200)
      end
    end
  end

  test "unavailable token storage preserves the cookie and cannot report logout", %{ip: ip} do
    user = register()
    anonymous = get(build_conn(), "/api/session")
    csrf = json_response(anonymous, 200)["csrf_token"]

    signed_in =
      write(anonymous, :post, %{email: to_string(user.email), password: @password}, csrf, ip)

    csrf = json_response(signed_in, 200)["csrf_token"]
    token = get_session(signed_in, "user_token")
    Repo.query!("ALTER TABLE platform_tokens RENAME TO unavailable_tokens", [])

    log =
      capture_log(fn ->
        refused = write(signed_in, :delete, %{}, csrf, ip)
        assert refused.status in [401, 503]
        assert refused.resp_cookies == %{}
        refute Map.has_key?(json_response(refused, refused.status), "authenticated")
        current = signed_in |> recycle() |> get("/api/session")
        assert current.status in [401, 503]
        assert current.resp_cookies == %{}
      end)

    refute log =~ token
    refute log =~ @password
    refute log =~ to_string(user.email)
  end

  test "no account provisioning, recovery or catalog write route is opened" do
    for path <- [
          "/api/users",
          "/api/register",
          "/api/password/reset",
          "/api/sources",
          "/api/profiles"
        ] do
      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post(path, "{}")
             |> response(404)
    end
  end

  defp register do
    email = "session-#{Ecto.UUID.generate()}@example.com"

    assert {:ok, user} =
             Authentication.register(%{
               email: email,
               password: @password,
               password_confirmation: @password
             })

    user
  end

  defp request(conn, csrf, ip) do
    conn =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://www.example.com")
      |> put_req_header("x-csrf-token", csrf)

    %{conn | remote_ip: ip}
  end

  defp write(conn, method, body, csrf, ip),
    do:
      Phoenix.ConnTest.dispatch(
        request(conn, csrf, ip),
        @endpoint,
        method,
        "/api/session",
        Jason.encode!(body)
      )
end
