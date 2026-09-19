import Config

config :phoenix, :filter_parameters, [
  "token",
  "password",
  "secret",
  "code",
  "state",
  "nonce",
  "error_description"
]

# Values remain environment references; no provider is contacted at boot.
config :ops_brain, :oidc,
  enabled: System.get_env("OPS_BRAIN_OIDC_ENABLED") == "true",
  reviewed: "OPS_BRAIN_OIDC_REVIEWED",
  issuer: "OPS_BRAIN_OIDC_ISSUER",
  authorization_endpoint: "OPS_BRAIN_OIDC_AUTHORIZATION_ENDPOINT",
  token_endpoint: "OPS_BRAIN_OIDC_TOKEN_ENDPOINT",
  jwks_uri: "OPS_BRAIN_OIDC_JWKS_URI",
  redirect_uri: "OPS_BRAIN_OIDC_REDIRECT_URI",
  client_id: "OPS_BRAIN_OIDC_CLIENT_ID",
  auth_method: "OPS_BRAIN_OIDC_AUTH_METHOD",
  client_secret: "OPS_BRAIN_OIDC_CLIENT_SECRET",
  subjects: "OPS_BRAIN_OIDC_SUBJECTS"

if System.get_env("PHX_SERVER") == "true" do
  config :ops_brain, OpsBrainWeb.Endpoint, server: true
end

config :ops_brain, OpsBrainWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  config :ops_brain, OpsBrain.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    ssl: [verify: :verify_peer, cacertfile: System.fetch_env!("DATABASE_CA_FILE")],
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :ops_brain, OpsBrainWeb.Endpoint,
    url: [host: System.fetch_env!("PHX_HOST"), port: 443, scheme: "https"],
    http: [ip: {127, 0, 0, 1}],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
else
  database = if config_env() == :test, do: "ops_brain_test", else: "ops_brain_dev"
  url = System.get_env("DATABASE_URL", "ecto://ops_brain_runtime@localhost:55432/#{database}")
  config :ops_brain, OpsBrain.Repo, url: url

  if config_env() == :test do
    admin_url =
      System.get_env(
        "MIGRATION_DATABASE_URL",
        "ecto://ops_brain_migrator@localhost:55432/ops_brain_test"
      )

    for candidate <- [url, admin_url] do
      unless String.starts_with?(URI.parse(candidate).path || "", "/ops_brain_test") do
        raise "Tests require a dedicated ops_brain_test database; fixture cleanup is destructive."
      end
    end

    config :ops_brain, OpsBrain.TestAdminRepo, url: admin_url
  end
end
