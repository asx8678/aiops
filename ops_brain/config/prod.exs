import Config
config :ops_brain, :secure_cookies, true

config :ops_brain, OpsBrainWeb.Endpoint, force_ssl: [hsts: true]
config :logger, level: :info
