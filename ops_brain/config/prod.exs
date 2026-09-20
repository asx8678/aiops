import Config

config :ops_brain, :secure_cookies, true

# Forwarded-proto is trusted only from the approved local TLS proxy; the default
# production listener binds loopback (see config/runtime.exs HTTP_BIND). This is
# compile-time Phoenix configuration, so it lives in the shared config path used
# by both native and container releases instead of being appended only in-image.
config :ops_brain, OpsBrainWeb.Endpoint, force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]

config :logger, level: :info
