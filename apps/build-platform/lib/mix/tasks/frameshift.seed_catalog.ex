defmodule Mix.Tasks.Frameshift.SeedCatalog do
  @moduledoc """
  Imports reviewed local candidates under an explicitly supplied editor identity.

  Run from the platform application with `--actor UUID --directory PATH`.
  Both arguments are required; positional or unknown options refuse. The task
  loads application configuration, disables HTTP serving and starts the application
  before invoking `FrameshiftPlatform.Catalog.SeedImport.run/2`.

  ## Attribution and retries

  The actor UUID attributes this local administrative operation; it is not proof
  of an authenticated browser session. Seed import reuses identical revisions,
  stops on conflicts and preserves earlier committed records if a later item
  fails. Successful completion prints counts; refused input raises a Mix error.
  No seed import occurs implicitly at normal application startup.
  """

  use Mix.Task
  alias FrameshiftPlatform.Access.Actor
  alias FrameshiftPlatform.Catalog.SeedImport

  @shortdoc "Import public catalog seeds (--actor UUID --directory PATH)"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [actor: :string, directory: :string])
    id = opts[:actor]
    directory = opts[:directory]

    unless rest == [] and invalid == [] and is_binary(directory) and
             match?({:ok, _}, Ecto.UUID.cast(id)) do
      Mix.raise("Required: --actor UUID --directory PATH")
    end

    Mix.Task.run("app.config")
    endpoint = FrameshiftPlatformWeb.Endpoint
    config = Application.fetch_env!(:frameshift_platform, endpoint)
    Application.put_env(:frameshift_platform, endpoint, Keyword.put(config, :server, false))
    Mix.Task.run("app.start")

    case SeedImport.run(directory, %Actor{id: id, role: :catalog_editor}) do
      {:ok, counts} ->
        Mix.shell().info(
          "Catalog import complete: #{counts.sources} sources, #{counts.profiles} profiles"
        )

      {:error, error} ->
        Mix.raise("Catalog import refused: #{inspect(error)}")
    end
  end
end
