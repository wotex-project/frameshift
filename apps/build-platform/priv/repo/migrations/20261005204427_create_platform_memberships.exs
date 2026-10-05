defmodule FrameshiftPlatform.Repo.Migrations.CreatePlatformMemberships do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:platform_memberships, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:role, :text, null: false)
      add(:version, :bigint, null: false, default: 1)
      add(:granted_by, :uuid, null: false)
      add(:granted_at, :utc_datetime_usec, null: false)
      add(:revoked_by, :uuid)
      add(:revoked_at, :utc_datetime_usec)

      add(
        :user_id,
        references(:platform_users,
          column: :id,
          name: "platform_memberships_user_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    create unique_index(:platform_memberships, [:user_id, :role],
             name: "platform_memberships_active_user_role_index",
             where: "(revoked_at IS NULL)"
           )

    create constraint(:platform_memberships, :platform_memberships_role,
             check: """
               role IN ('catalog_editor', 'research_worker', 'operator')
             """
           )

    create constraint(:platform_memberships, :platform_memberships_lifecycle,
             check: """
               (version = 1 AND revoked_at IS NULL AND revoked_by IS NULL) OR (version = 2 AND revoked_at IS NOT NULL AND revoked_by IS NOT NULL)
             """
           )
  end

  def down do
    drop(table(:platform_memberships))
  end
end
