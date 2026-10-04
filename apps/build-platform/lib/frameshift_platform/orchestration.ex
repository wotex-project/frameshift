defmodule FrameshiftPlatform.Orchestration do
  @moduledoc """
  Configures the platform's single embedded Refpath runtime.

  `contract/0` binds the pinned producer revision to
  `FrameshiftPlatform.Repo` and the platform PubSub service. Refpath uses durable
  storage while the host owns the database pool and infrastructure. Embedded
  process deployment and self-hosted infrastructure are explicit separate settings.

  ## Startup and readiness

  `child_specs/0` returns the producer child only when `:orchestration_enabled`
  is configured. `readiness/0` invokes Refpath's public boot-contract probe; it
  is not proof that additional operator, effect or Conjunct profiles are qualified.

  The contract disables autonomous/model-serving processes, native embeddings,
  plugins, producer log handlers and Beamlens. It reuses host PubSub and supplies
  sandbox configuration explicitly. Extending enabled capability scope requires
  separate consumer evidence rather than copying upstream development defaults.
  """

  alias Refpath.BootConfig.Contract
  alias Refpath.BootConfig.Readiness

  @revision "ee60f58cb885f8fe6875ce9468b0c6ffdb5496c0"

  @spec revision() :: String.t()
  def revision, do: @revision

  @spec contract() :: Contract.t()
  def contract do
    %Contract{
      deployment_mode: :embedded,
      repo_mode: :durable,
      repo: FrameshiftPlatform.Repo,
      pubsub: FrameshiftPlatform.PubSub,
      security_profile: :local_loopback,
      settings: %{
        hosting_mode: :self_hosted,
        skip_pubsub: true,
        beamlens_enabled: false,
        autonomous_enabled: false,
        ml_serving: [enabled: false],
        forecast_serving: [enabled: false],
        native_embedding: [enabled: false],
        lightweight: true,
        install_log_handler: false,
        plugin_runtime_enabled: false,
        sql_sandbox: Application.get_env(:frameshift_platform, :sql_sandbox, false)
      }
    }
  end

  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    if Application.get_env(:frameshift_platform, :orchestration_enabled, false) do
      [Contract.child_spec(contract())]
    else
      []
    end
  end

  @spec readiness() :: {:ok, map()} | {:error, term()}
  def readiness, do: Readiness.readiness(contract())
end
