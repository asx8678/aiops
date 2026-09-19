import Config

config :ops_brain, OpsBrain.Repo, pool_size: 1
config :ops_brain, OpsBrain.TestAdminRepo, pool_size: 1

config :ops_brain, OpsBrainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "48O+jwYHWmTfE7cK33iuibMoEaNLSdIapCDeZmG/H814ixyiGunJwmT0+xDSsUKO",
  server: false

config :ops_brain, Oban, testing: :manual
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true
