import Config

config :frameshift_platform, :secure_session_cookie, false

config :frameshift_platform,
       :authentication_signing_secret,
       "frameshift-isolated-auth-test-key-not-for-production-000000000000000"

config :refpath, Refpath.Security.Vault,
  ciphers: [aes_gcm: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: <<1::256>>, iv_length: 12}]

config :frameshift_platform, FrameshiftPlatform.Repo,
  hostname: "127.0.0.1",
  port: 54329,
  username: "frameshift_dev",
  password: "frameshift_local_only",
  database: System.get_env("FRAMESHIFT_PLATFORM_TEST_DATABASE", "frameshift_platform_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :frameshift_platform, FrameshiftPlatformWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4081],
  check_origin: ["http://www.example.com"],
  secret_key_base:
    "frameshift-isolated-test-secret-not-for-production-00000000000000000000000000000",
  server: false

config :ash, :disable_async?, true
config :frameshift_platform, :sql_sandbox, true
config :logger, level: :warning
