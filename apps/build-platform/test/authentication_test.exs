defmodule FrameshiftPlatform.AuthenticationTest do
  @moduledoc false

  use FrameshiftPlatform.DataCase, async: false
  import ExUnit.CaptureLog
  alias FrameshiftPlatform.Access.{Actor, Authentication, Token, User}
  alias FrameshiftPlatform.Repo

  @password " a long private password 🔒 "

  test "registration persists unique salted Argon2id credentials, never plaintext" do
    first = register()
    second = register()
    assert first.hashed_password =~ "$argon2id$"
    assert first.hashed_password =~ "$m=65536,t=3,p=4$"
    refute first.hashed_password == second.hashed_password
    assert Argon2.verify_pass(@password, first.hashed_password)

    %{rows: rows} = Repo.query!("SELECT hashed_password FROM platform_users", [])
    assert length(rows) == 2
    for [hash] <- rows, do: refute(hash =~ @password)

    assert {:error, :invalid_credentials} =
             Authentication.register(credentials(String.upcase(to_string(first.email))))

    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM platform_users", [])
  end

  test "password whitespace and all 128 Unicode code points survive hashing" do
    password = String.duplicate("🔒", 128)
    user = register(password: password)

    assert {:ok, same} =
             Authentication.sign_in(%{email: to_string(user.email), password: password})

    assert same.id == user.id

    assert {:error, :invalid_credentials} =
             Authentication.sign_in(%{
               email: to_string(user.email),
               password: String.slice(password, 0, 127)
             })

    spaced = register()

    assert {:error, :invalid_credentials} =
             Authentication.sign_in(%{
               email: to_string(spaced.email),
               password: String.trim(@password)
             })
  end

  test "password bounds count code points and preserve combining-character bytes" do
    password = String.duplicate("e\u0301", 8)
    assert String.length(password) == 8
    assert length(String.codepoints(password)) == 16
    user = register(password: password)
    assert {:ok, _} = Authentication.sign_in(%{email: to_string(user.email), password: password})

    assert {:error, :invalid_credentials} =
             Authentication.sign_in(%{
               email: to_string(user.email),
               password: String.normalize(password, :nfc)
             })
  end

  test "invalid shapes and password bounds refuse before creating accounts or tokens" do
    for params <- [
          nil,
          %{"email" => "a@example.com", "password" => @password},
          Map.put(credentials(), :role, :operator),
          credentials(password: String.duplicate("a", 14)),
          credentials(password: String.duplicate("a", 129)),
          credentials(password: <<255>>),
          credentials(email: String.duplicate("a", 255)),
          credentials(password: nil)
        ] do
      assert {:error, :invalid_input} = Authentication.register(params)
    end

    assert {:error, :invalid_credentials} =
             Authentication.register(credentials(password_confirmation: "different password"))

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_users", [])
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])
  end

  test "wrong and missing credentials have the same finite refusal and create no token" do
    user = register()

    for email <- [to_string(user.email), "missing@example.com"] do
      assert {:error, :invalid_credentials} =
               Authentication.sign_in(%{email: email, password: "wrong password"})
    end

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])

    assert {:ok, signed_in} =
             Authentication.sign_in(%{
               email: String.upcase(to_string(user.email)),
               password: @password
             })

    assert signed_in.id == user.id
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])
  end

  test "issued session requires signature, twelve-hour expiry and token presence" do
    user = register()
    token = user.__metadata__.token
    assert {:ok, claims} = AshAuthentication.Jwt.peek(token)
    assert claims["exp"] - claims["iat"] == 12 * 60 * 60
    assert {:ok, current} = Authentication.authenticate(token)
    assert current.id == user.id
    assert {:error, :invalid_credentials} = Authentication.authenticate(tamper(token))

    Repo.query!("DELETE FROM platform_tokens WHERE jti = $1", [claims["jti"]])
    assert {:error, :invalid_credentials} = Authentication.authenticate(token)
  end

  test "expired signed tokens and missing current accounts refuse" do
    user = register()

    assert {:ok, expired, _} =
             AshAuthentication.Jwt.token_for_user(user, %{
               "exp" => System.system_time(:second) - 60
             })

    assert {:error, :invalid_credentials} = Authentication.authenticate(expired)

    Repo.query!("DELETE FROM platform_users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
    assert {:error, :invalid_credentials} = Authentication.authenticate(user.__metadata__.token)
  end

  test "current account is loaded on each request without authority from token claims" do
    user = register()

    Repo.query!("UPDATE platform_users SET email = $1 WHERE id = $2", [
      "current@example.com",
      Ecto.UUID.dump!(user.id)
    ])

    assert {:ok, current} = Authentication.authenticate(user.__metadata__.token)
    assert to_string(current.email) == "current@example.com"
    refute Actor.allowed?(current, [:operator, :catalog_editor])
    assert {:error, _} = Ash.read(FrameshiftPlatform.Access.AuditEvent, actor: current)
  end

  test "forged revocation cannot affect a valid stored token" do
    user = register()
    token = user.__metadata__.token
    assert {:error, :invalid_credentials} = Authentication.revoke(tamper(token))
    assert {:ok, _} = Authentication.authenticate(token)
    assert :ok = Authentication.revoke(token)
    assert {:error, :invalid_credentials} = Authentication.authenticate(token)
    assert %{rows: [["revocation"]]} = Repo.query!("SELECT purpose FROM platform_tokens", [])
  end

  test "ordinary Ash reads and credential creation cannot bypass authentication policy" do
    for resource <- [User, Token],
        actor <- [nil, %Actor{id: Ecto.UUID.generate(), role: :operator}] do
      assert {:error, _} = Ash.read(resource, actor: actor)
    end

    assert {:error, _} =
             User
             |> Ash.Changeset.for_create(:register_with_password, credentials())
             |> Ash.create()

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_users", [])
  end

  test "missing signing configuration refuses before persistence" do
    key = Application.fetch_env!(:frameshift_platform, :authentication_signing_secret)
    Application.delete_env(:frameshift_platform, :authentication_signing_secret)

    on_exit(fn ->
      Application.put_env(:frameshift_platform, :authentication_signing_secret, key)
    end)

    assert {:error, :unavailable} = Authentication.register(credentials())

    assert {:error, :unavailable} =
             Authentication.sign_in(%{email: "missing@example.com", password: @password})

    assert {:error, :unavailable} = Authentication.authenticate("opaque")
    assert {:error, :unavailable} = Authentication.revoke("opaque")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_users", [])
  end

  test "storage failure cannot authorize a session or report completed revocation" do
    user = register()
    token = user.__metadata__.token
    # This DDL exists only inside the sandbox transaction, never a product migration.
    Repo.query!("ALTER TABLE platform_tokens RENAME TO unavailable_tokens", [])

    log =
      capture_log(fn ->
        assert {:error, _} = Authentication.authenticate(token)
        assert {:error, _} = Authentication.revoke(token)
      end)

    refute log =~ token
    refute log =~ to_string(user.email)
    refute log =~ @password
  end

  test "credential actions do not log plaintext, email or session tokens" do
    email = "private-log-canary@example.com"

    log =
      capture_log(fn ->
        user = register(email: email)
        token = user.__metadata__.token
        assert {:ok, _} = Authentication.authenticate(token)

        assert {:error, :invalid_credentials} =
                 Authentication.sign_in(%{email: email, password: "wrong password"})

        assert :ok = Authentication.revoke(token)
        refute token =~ @password
      end)

    refute log =~ email
    refute log =~ @password
    refute log =~ "eyJ"
    assert Repo.config()[:log] == false
  end

  defp register(overrides \\ []) do
    assert {:ok, user} = Authentication.register(credentials(overrides))
    user
  end

  defp credentials(overrides \\ [])
  defp credentials(email) when is_binary(email), do: credentials(email: email)

  defp credentials(overrides) do
    defaults = %{
      email: "account-#{Ecto.UUID.generate()}@example.com",
      password: @password,
      password_confirmation: @password
    }

    defaults =
      if Keyword.has_key?(overrides, :password),
        do: Map.put(defaults, :password_confirmation, overrides[:password]),
        else: defaults

    Map.merge(defaults, Map.new(overrides))
  end

  defp tamper(token) do
    [header, payload, signature] = String.split(token, ".")
    changed = if String.starts_with?(signature, "A"), do: "B", else: "A"
    Enum.join([header, payload, changed <> String.slice(signature, 1..-1//1)], ".")
  end
end
