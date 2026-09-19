import Config

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
