defmodule FrameshiftPlatform.Repo.Migrations.CreatePlatformAuditEvents do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:platform_audit_events, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:actor_id, :uuid, null: false)
      add(:subject_id, :uuid, null: false)
      add(:event, :text, null: false)

      add(:recorded_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end
  end

  def down do
    drop(table(:platform_audit_events))
  end
end
