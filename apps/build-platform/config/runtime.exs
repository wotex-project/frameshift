import Config

config :frameshift_platform, :metrics_token, System.get_env("FRAMESHIFT_METRICS_TOKEN")

if config_env() == :prod do
  authentication_key = System.fetch_env!("AUTH_TOKEN_SIGNING_SECRET") |> Base.decode64!()

  if byte_size(authentication_key) != 32,
    do: raise("AUTH_TOKEN_SIGNING_SECRET must encode exactly 32 bytes")

  config :frameshift_platform, :authentication_signing_secret, authentication_key

  cloak_key = System.fetch_env!("CLOAK_KEY") |> Base.decode64!()

  if byte_size(cloak_key) != 32, do: raise("CLOAK_KEY must encode exactly 32 bytes")

  config :refpath, Refpath.Security.Vault,
    ciphers: [aes_gcm: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: cloak_key, iv_length: 12}]

  config :frameshift_platform, FrameshiftPlatform.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  host = System.fetch_env!("PHX_HOST")

  config :frameshift_platform, FrameshiftPlatformWeb.Endpoint,
    server: true,
    url: [scheme: "https", host: host, port: 443],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4080"))],
    check_origin: ["https://#{host}"],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
