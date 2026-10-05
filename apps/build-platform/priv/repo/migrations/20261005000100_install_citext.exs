defmodule FrameshiftPlatform.Repo.Migrations.InstallCitext do
  @moduledoc false

  use Ecto.Migration

  def up, do: execute("CREATE EXTENSION IF NOT EXISTS citext")
  def down, do: execute("DROP EXTENSION IF EXISTS citext")
end
