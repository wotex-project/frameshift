defmodule FrameshiftPlatform.Repo.Migrations.CreatePlatformUsers do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:platform_users, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:email, :citext, null: false)
      add(:hashed_password, :text, null: false)
    end

    create unique_index(:platform_users, [:email], name: :platform_users_unique_email_index)
  end

  def down, do: drop(table(:platform_users))
end
