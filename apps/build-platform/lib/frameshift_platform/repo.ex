defmodule FrameshiftPlatform.Repo do
  @moduledoc """
  Owns the platform's PostgreSQL pool and catalog persistence.

  Ash resources use the `public` schema by default. The connection hook sets
  `search_path` to `public, refpath` so the embedded producer can resolve its
  runtime SQL while Ecto's unqualified migration ledger remains in `public`.
  `FrameshiftPlatform.Orchestration` injects this pool into Refpath; no second
  runtime Repo or parallel database is started here.

  ## Database requirements

  The Repo advertises PostgreSQL 18 and the installed Ash helper-function
  and citext extensions. SQL query logging is disabled because bind parameters
  can contain account identifiers and credentials; bounded timing telemetry
  remains available. Schema ownership and fresh-install/rollback behavior are
  verified through platform migrations. This database is independent of the native
  `Frameshift.Library` SQLite store; the platform never opens that local store.
  """

  use AshPostgres.Repo, otp_app: :frameshift_platform

  @impl true
  def default_options(_), do: [prefix: "public"]

  @impl true
  def init(type, config) do
    {:ok, config} = super(type, config)

    {:ok,
     Keyword.put(
       config,
       :after_connect,
       {Postgrex, :query!, ["SET search_path TO public, refpath", []]}
     )}
  end

  @impl true
  def installed_extensions, do: ["ash-functions", "citext"]

  @impl true
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
