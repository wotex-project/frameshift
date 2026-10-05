defmodule FrameshiftPlatformWeb.SessionController do
  @moduledoc """
  Exposes finite browser-session state, bounded sign-in and verified sign-out.

  `show/2` returns an authenticated boolean and a session-bound CSRF token.
  `create/2` accepts exactly JSON email/password fields and admits native work
  through `FrameshiftPlatform.Access.PasswordWork.sign_in/2`. Successful sign-in
  renews the encrypted session and CSRF state through the upstream Plug helpers.
  No authentication token, account field, role or scope is projected to JSON.

  ## Refusal and logout

  `delete/2` accepts an empty JSON body and revokes the current stored token before
  clearing the session. Failed verification/revocation preserves cookie custody
  and returns a finite refusal; it cannot claim completed logout. Unknown current
  sessions also refuse without overwriting their cookie. Inputs come from body
  parameters only; query credentials and extra authority fields are rejected.
  Missing sessions can obtain anonymous CSRF state without an account. These
  routes provision no accounts and admit no catalog or composition commands.
  """

  use Phoenix.Controller, formats: [:json]
  alias FrameshiftPlatform.Access.{Authentication, PasswordWork}

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _) do
    case get_session(conn, "user_token") do
      nil ->
        state(conn, false)

      token ->
        case Authentication.authenticate(token) do
          {:ok, _} -> state(conn, true)
          {:error, reason} -> error(conn, reason)
        end
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _) do
    with {:ok, params} <- credentials(conn),
         {:ok, user} <- PasswordWork.sign_in(conn.remote_ip, params) do
      Plug.CSRFProtection.delete_csrf_token()

      conn
      |> clear_session()
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> state(true)
    else
      {:error, reason} -> error(conn, reason)
    end
  catch
    _, _ -> error(conn, :unavailable)
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _) do
    with :ok <- empty_body(conn),
         :ok <- revoke_session(get_session(conn, "user_token")) do
      signed_out(conn)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp credentials(%{
         body_params: %{"email" => email, "password" => password} = body,
         query_params: query
       })
       when map_size(body) == 2 and map_size(query) == 0 and is_binary(email) and
              is_binary(password) and byte_size(email) <= 254 and byte_size(password) <= 512,
       do: {:ok, %{email: email, password: password}}

  defp credentials(_), do: {:error, :invalid_input}

  defp empty_body(%{body_params: body, query_params: query})
       when map_size(body) == 0 and map_size(query) == 0, do: :ok

  defp empty_body(_), do: {:error, :invalid_input}
  defp revoke_session(nil), do: :ok
  defp revoke_session(token), do: Authentication.revoke(token)

  defp signed_out(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> clear_session() |> configure_session(renew: true) |> state(false)
  end

  defp state(conn, authenticated),
    do:
      json(
        conn,
        FrameshiftPlatformWeb.SessionView.project(
          authenticated,
          Plug.CSRFProtection.get_csrf_token()
        )
      )

  defp error(conn, reason) do
    {status, public} =
      case reason do
        :invalid_input -> {400, "invalid_input"}
        :invalid_credentials -> {401, "invalid_credentials"}
        :limited -> {429, "limited"}
        _ -> {503, "unavailable"}
      end

    conn = if status == 429, do: put_resp_header(conn, "retry-after", "60"), else: conn
    conn |> put_status(status) |> json(%{error: public})
  end
end
