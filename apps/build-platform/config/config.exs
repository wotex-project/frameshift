import Config

config :ash,
  default_string_length_count: :codepoints,
  infer_generic_action_reactors?: false

config :argon2_elixir, argon2_type: 2, t_cost: 3, m_cost: 16, parallelism: 4
config :prometheus, collectors: []
config :frameshift_platform, ecto_repos: [FrameshiftPlatform.Repo]
config :frameshift_platform, :ash_domains, [FrameshiftPlatform.Access, FrameshiftPlatform.Catalog]

config :frameshift_platform, FrameshiftPlatform.Repo,
  types: Refpath.Repo.PostgrexTypes,
  migration_default_prefix: "public",
  log: false

config :frameshift_platform, :orchestration_enabled, config_env() != :test
config :refpath, :storage_adapter, :postgres

config :frameshift_platform, FrameshiftPlatformWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: FrameshiftPlatformWeb.ErrorJSON], layout: false],
  pubsub_server: FrameshiftPlatform.PubSub

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "password_confirmation", "token"]

config :phoenix_assets,
  otp_app: :frameshift_platform,
  endpoint: FrameshiftPlatformWeb.Endpoint,
  router: FrameshiftPlatformWeb.Router,
  package_manager: :npm

config :phoenix_assets, :stack,
  locales: ["en"],
  default_locale: "en",
  types: FrameshiftPlatform.Assets.Types

config :phoenix_assets, :dev, enabled: false, storybook: [enabled: false]

import_config "#{config_env()}.exs"
