# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and is restricted
# to this project.

import Config

config :ops_brain,
  ecto_repos: [OpsBrain.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :ops_brain, OpsBrainWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OpsBrainWeb.ErrorHTML, json: OpsBrainWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OpsBrain.PubSub,
  live_view: [signing_salt: "A9dOCUQt"]

# Configure LiveView
config :phoenix_live_view, root_tag_attribute: "phx-r"

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :ops_brain, OpsBrain.Repo, log: false

config :ops_brain, Oban,
  repo: OpsBrain.Repo,
  queues: [collect: 4, enrich: 2, delivery: 1, maintenance: 1],
  plugins: [
    {Oban.Lifeline, rescue_after: {10, :minutes}, interval: {1, :minute}}
  ],
  peer: Oban.Peers.Database

config :ops_brain,
  maintenance_enabled: false,
  collection_enabled: false,
  delivery_enabled: false,
  metrics_console: false,
  sources: %{},
  notification_sinks: %{}

config :phoenix, :filter_parameters, ["token", "password", "secret"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
