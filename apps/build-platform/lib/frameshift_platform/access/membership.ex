defmodule FrameshiftPlatform.Access.Membership do
  @moduledoc """
  Retains one private, attributed grant of a global catalog permission.

  `FrameshiftPlatform.Access.Memberships.grant/4` binds a stable UUID to one
  current account, catalog role and trusted local administrator. The supported
  roles are catalog editor, research worker and the existing catalog-audit reader.
  No membership supplies generic operator, project or composition authority.

  ## Lifecycle and persistence

  A grant starts at version 1. Its identity, account, role, administrator and
  creation time are immutable. Revocation records its own administrator/time and
  advances once to version 2 through optimistic locking. Revoked rows remain;
  regrant uses a new UUID. PostgreSQL enforces one active grant per account/role
  and the version/revocation shape. Account deletion with retained grants refuses.

  ## Permission boundary

  Ordinary account actors cannot read or write this resource. Provisioning uses
  a trusted local `FrameshiftPlatform.Access.Actor` with `:access_admin`, which
  cannot be assigned by these grants. There is no browser route or generated
  schema. `FrameshiftPlatform.Access.Memberships.actor_for/2` derives account
  identity from a verified session; Ash catalog policies recheck its exact
  membership reference. A record or role name alone authenticates no caller.
  """

  use Ash.Resource,
    domain: FrameshiftPlatform.Access,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "platform_memberships"
    repo FrameshiftPlatform.Repo
    identity_wheres_to_sql active_user_role: "revoked_at IS NULL"

    check_constraints do
      check_constraint :role, "platform_memberships_role",
        check: "role IN ('catalog_editor', 'research_worker', 'operator')"

      check_constraint :version, "platform_memberships_lifecycle",
        check:
          "(version = 1 AND revoked_at IS NULL AND revoked_by IS NULL) OR (version = 2 AND revoked_at IS NOT NULL AND revoked_by IS NOT NULL)"
    end
  end

  actions do
    defaults [:read]

    create :grant do
      accept [:id, :user_id, :role]
      change {FrameshiftPlatform.Access.AttributeMembership, event: :grant}
    end

    update :revoke do
      accept []
      require_atomic? false
      validate attribute_equals(:version, 1)
      change {FrameshiftPlatform.Access.AttributeMembership, event: :revoke}
      change optimistic_lock(:version)
    end
  end

  policies do
    policy always() do
      authorize_if {FrameshiftPlatform.Access.RoleCheck, roles: [:access_admin]}
    end
  end

  attributes do
    uuid_primary_key :id, public?: false, writable?: true

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:catalog_editor, :research_worker, :operator]]

    attribute :version, :integer, allow_nil?: false, default: 1, writable?: false
    attribute :granted_by, :uuid, allow_nil?: false, writable?: false, sensitive?: true
    attribute :granted_at, :utc_datetime_usec, allow_nil?: false, writable?: false
    attribute :revoked_by, :uuid, writable?: false, sensitive?: true
    attribute :revoked_at, :utc_datetime_usec, writable?: false
  end

  relationships do
    belongs_to :user, FrameshiftPlatform.Access.User, allow_nil?: false
  end

  identities do
    identity :active_user_role, [:user_id, :role], where: expr(is_nil(revoked_at))
  end
end
