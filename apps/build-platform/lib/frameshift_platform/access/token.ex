defmodule FrameshiftPlatform.Access.Token do
  @moduledoc """
  Persists the platform authentication token lifecycle.

  `AshAuthentication.TokenResource` supplies the token schema and actions used
  by `FrameshiftPlatform.Access.User`. Issuance stores each token; authentication
  requires its presence, and the upstream verifier enforces signature, purpose,
  expiry and revocation. `AshAuthentication.Supervisor` removes expired token
  records through the public token-resource boundary.

  ## Storage and permissions

  Records belong to the existing platform PostgreSQL pool and Access domain.
  Only an Ash Authentication interaction may use the generated actions. Ordinary
  reads/writes and public catalog projections have no token access. A browser
  logout must complete revocation before reporting success; storage failure is
  an unavailable authentication boundary rather than permission to trust a
  cookie or decoded claim.

  This resource does not authenticate workers, grant operator membership or
  manage the native application's keys. Consumers must discard token values
  from responses, URLs, diagnostics and frontend storage, and use the current
  server account/permission boundary for each authenticated command.
  """

  use Ash.Resource,
    domain: FrameshiftPlatform.Access,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "platform_tokens"
    repo FrameshiftPlatform.Repo

    custom_indexes do
      index [:expires_at]
      index [:subject]
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
end
