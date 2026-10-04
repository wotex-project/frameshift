defmodule FrameshiftPlatform.Repo.Migrations.InstallRefpath do
  @moduledoc false

  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: Refpath.Migrations.up(1)
  def down, do: Refpath.Migrations.down(0)
end
