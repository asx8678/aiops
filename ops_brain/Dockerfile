# syntax=docker/dockerfile:1
# Real upstream tag; verify platform, scan and record resolved digest before approval.
# Same base in both stages intentionally avoids OTP/OpenSSL/libc ABI mismatch.
ARG ELIXIR_IMAGE=elixir:1.20.4-otp-27-slim
FROM ${ELIXIR_IMAGE} AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libstdc++6 openssl \
    && rm -rf /var/lib/apt/lists/*

FROM base AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /build
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
COPY rel rel
# Production behavior lives in the shared config/ files; no in-image source
# concatenation. See docs/DEPLOYMENT.md.
RUN mix compile --warnings-as-errors \
    && mix phx.digest \
    && mix release \
    && chmod 0555 _build/prod/rel/ops_brain/bin/release-command \
                  _build/prod/rel/ops_brain/bin/healthcheck

FROM base AS runtime
RUN groupadd --gid 10001 opsbrain \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin opsbrain
WORKDIR /app
COPY --from=build --chown=0:0 /build/_build/prod/rel/ops_brain ./
ENV HOME=/tmp LANG=C.UTF-8 RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp/ops_brain
USER 10001:10001
# No EXPOSE: production listener remains 127.0.0.1, for a trusted host TLS proxy.
HEALTHCHECK --interval=60s --timeout=15s --start-period=30s --retries=3 \
    CMD ["/app/bin/healthcheck"]
ENTRYPOINT ["/app/bin/release-command"]
CMD ["disabled"]
