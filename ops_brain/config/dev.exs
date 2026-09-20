import Config

# Local demo is the single home workspace; this selects existing data, never seeds it.
config :ops_brain, :workspace_company_id, "c057e110-0000-4000-8000-000000000001"

config :ops_brain, OpsBrain.Repo, pool_size: 5

config :ops_brain, OpsBrainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "rzH6T6sptXbtFuCbqDzmQ8lDeekUIFVt1tF34Vlgos51InaF7QUVPq4UKfxaAsqe",
  watchers: []

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :plug_init_mode, :runtime

# Temporary local convenience requested by the owner. No identities/memberships
# are created. DevAutoLogin is compiled only in :dev; every page GET can issue a
# session regardless of host/proxy headers. Keep the dev listener private.
# Disabling this flag and restarting restores normal login.
config :ops_brain,
  dev_auto_login: System.get_env("OPS_BRAIN_DEV_AUTOLOGIN", "true") == "true",
  dev_operator: System.get_env("OPS_BRAIN_DEV_OPERATOR", "adam")
