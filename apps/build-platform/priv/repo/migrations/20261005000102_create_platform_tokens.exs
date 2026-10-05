defmodule FrameshiftPlatform.Repo.Migrations.CreatePlatformTokens do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:platform_tokens, primary_key: false) do
      add(:jti, :text, null: false, primary_key: true)
      add(:subject, :text, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:purpose, :text, null: false)
      add(:extra_data, :map)

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:platform_tokens, [:expires_at])
    create index(:platform_tokens, [:subject])
  end

  def down, do: drop(table(:platform_tokens))
end
