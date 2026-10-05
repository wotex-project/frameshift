defmodule FrameshiftPlatform.Access.User do
  @moduledoc """
  Stores a private platform account and its password credential.

  `AshAuthentication.Strategy.action/4` owns registration and sign-in through the
  `:password` strategy. Registration accepts an email identifier and matching,
  untrimmed passwords of 15–128 Unicode code points. The resource persists an
  Argon2id hash; plaintext arguments are sensitive and are never attributes.
  Email uniqueness is case insensitive. An email identifier does not establish
  mailbox ownership or grant an operator or catalog role.

  ## Authentication and token custody

  `FrameshiftPlatform.Access.Token` stores issued tokens. Authentication requires
  a verified signature, unexpired 12-hour lifetime and stored-token presence.
  The signing secret comes from runtime configuration; it is never a resource
  attribute or a compiled secret. Missing configuration or token storage cannot
  authorize a session. `AshAuthentication.Supervisor` owns expiry maintenance.

  ## Consumers and permissions

  This resource belongs to `FrameshiftPlatform.Access` and the platform's
  PostgreSQL database, independently of native artwork custody. Ordinary Ash
  reads and writes refuse; only the authentication interaction can use its
  actions. Browser controllers must project explicit session fields, protect
  cookie/CSRF custody and derive permissions from current server membership.
  Returning a user from sign-in does not admit a catalog or composition command.
  Public catalog schemas deliberately exclude this resource.
  """

  use Ash.Resource,
    domain: FrameshiftPlatform.Access,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "platform_users"
    repo FrameshiftPlatform.Repo
  end

  authentication do
    domain FrameshiftPlatform.Access

    tokens do
      enabled? true
      token_resource FrameshiftPlatform.Access.Token
      store_all_tokens? true
      require_token_presence_for_authentication? true
      signing_algorithm "HS256"
      token_lifetime {12, :hours}

      signing_secret fn _, _ ->
        Application.fetch_env(:frameshift_platform, :authentication_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.Argon2Provider
        sign_in_tokens_enabled? false
      end
    end
  end

  actions do
    defaults [:read]

    create :register_with_password do
      accept [:email]

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 15, max_length: 128, trim?: false]

      argument :password_confirmation, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 15, max_length: 128, trim?: false]

      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation
      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
    end

    read :sign_in_with_password do
      get? true
      argument :email, :ci_string, allow_nil?: false, constraints: [max_length: 254]

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 1, max_length: 128, trim?: false]

      prepare AshAuthentication.Strategy.Password.SignInPreparation
      metadata :token, :string, allow_nil?: false
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string,
      allow_nil?: false,
      public?: true,
      sensitive?: true,
      constraints: [max_length: 254, match: ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u]

    attribute :hashed_password, :string, allow_nil?: false, sensitive?: true
  end

  identities do
    identity :unique_email, [:email]
  end
end
