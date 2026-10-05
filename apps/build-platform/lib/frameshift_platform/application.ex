defmodule FrameshiftPlatform.Application do
  @moduledoc """
  Starts the companion platform and its owned infrastructure.

  The supervisor starts the PostgreSQL Repo, named PubSub service and metric
  reporter, authentication expiry supervisor and bounded password task/limiter
  owners, followed by enabled Refpath child specifications, phoenix-assets
  children and the Phoenix endpoint. A `:one_for_one` strategy restarts failed
  children independently; dependency configuration is supplied by the host.

  ## Application boundary

  The companion platform has its own lifecycle and persistence, separate from
  the native artwork application. Optional runtime startup is selected by
  `FrameshiftPlatform.Orchestration.child_specs/0`; loading this module does not
  activate additional producer profiles. `config_change/3` forwards relevant
  configuration changes to the endpoint during release changes.
  """

  use Application

  @impl true
  def start(_, _) do
    children = [
      FrameshiftPlatform.Repo,
      {Phoenix.PubSub, name: FrameshiftPlatform.PubSub},
      FrameshiftPlatform.Telemetry.Reporter,
      {AshAuthentication.Supervisor, otp_app: :frameshift_platform},
      {Task.Supervisor, name: FrameshiftPlatform.Access.PasswordTasks, max_children: 2},
      FrameshiftPlatform.Access.PasswordWork
    ]

    children =
      children ++
        FrameshiftPlatform.Orchestration.child_specs() ++
        PhoenixAssets.child_specs() ++ [FrameshiftPlatformWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: FrameshiftPlatform.Supervisor)
  end

  @impl true
  def config_change(changed, _, removed) do
    FrameshiftPlatformWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
