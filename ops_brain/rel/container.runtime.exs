# Appended only inside the Docker build after the existing runtime.exs.
# No repository config edit. Forwarded-proto is trusted ONLY from the approved
# proxy; wildcard binding requires network isolation in a reviewed override.
if config_env() == :prod do
  bind =
    case System.get_env("HTTP_BIND", "127.0.0.1") do
      "127.0.0.1" -> {127, 0, 0, 1}
      "0.0.0.0" -> {0, 0, 0, 0}
      _ -> raise "HTTP_BIND must be 127.0.0.1 or 0.0.0.0"
    end

  config :ops_brain, OpsBrainWeb.Endpoint, http: [ip: bind]
end
