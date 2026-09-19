# Appended only to the image's config/prod.exs BEFORE app compilation.
# Phoenix force_ssl is compile-time configuration; never override only at runtime.
config :ops_brain, OpsBrainWeb.Endpoint, force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]
