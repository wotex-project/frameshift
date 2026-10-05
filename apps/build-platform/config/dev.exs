import Config

config :frameshift_platform,
       :authentication_signing_secret,
       "frameshift-development-auth-key-not-for-production-0000000000000000"

config :refpath, Refpath.Security.Vault,
  ciphers: [aes_gcm: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: <<0::256>>, iv_length: 12}]

config :frameshift_platform, FrameshiftPlatform.Repo,
  hostname: "127.0.0.1",
  port: 54329,
  username: "frameshift_dev",
  password: "frameshift_local_only",
  database: "frameshift_platform_dev",
  pool_size: 5

config :frameshift_platform, FrameshiftPlatformWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4080],
  check_origin: ["http://localhost:4080", "http://127.0.0.1:4080"],
  secret_key_base:
    "frameshift-local-development-secret-not-for-production-000000000000000000000000",
  server: true

config :logger, :console, format: "$time $metadata[$level] $message\n", metadata: [:request_id]
