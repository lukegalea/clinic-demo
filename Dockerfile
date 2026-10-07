# Multi-stage build producing a self-contained Elixir release for the
# clinic-demo Fly.io deployment.
#
# The two stages exist so the runtime image carries no compiler, no build
# tools and no source: a smaller image with a much smaller attack surface.
# What ships is the release plus the ERTS it was built against.
#
# Versions are pinned to the pairing CI uses (.github/actions/setup-elixir:
# OTP 27, Elixir 1.20 — the app needs 1.20 for the ~r"..."E regex modifiers
# and its boxic_* deps). If those ever disagree, "works locally" stops being
# evidence of anything.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION="27.3.4.18"
ARG DEBIAN_VERSION="bookworm-20261005-slim"

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --- build -------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies are copied and fetched before the application source, so an
# application-only change reuses the cached dependency layer.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# config/config.exs and config/prod.exs are compile-time; runtime.exs is not,
# and is copied later so that changing it does not invalidate the dependency
# compilation layer.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Node is needed for the browser packages the esbuild bundle resolves out of
# assets/node_modules (bpmn-js, dmn-js, mermaid, the a2ui lit elements —
# NODE_PATH in config/config.exs). esbuild and tailwind themselves are fetched
# as binaries by their mix tasks, so no fuller Node toolchain is required.
RUN if [ -f assets/package.json ]; then \
      apt-get update -y && apt-get install -y nodejs npm \
      && npm --prefix assets ci \
      && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# --- runtime -----------------------------------------------------------------
FROM ${RUNNER_IMAGE}

# `libxml2-utils` provides `xmllint`, and it belongs in the RUNTIME stage
# rather than the builder: ash_decisions validates a DMN document against the
# normative XSD by shelling out to it, so it is needed when a model LOADS —
# not when the release is compiled. (CI reaches the same conclusion: its
# setup action installs libxml2-utils before anything runs.)
RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates libxml2-utils \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# The BEAM wants a UTF-8 locale; without it, string handling misbehaves in ways
# that are tedious to diagnose.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Runs as a non-root user. A release needs no write access to its own files.
RUN chown nobody /app
ENV MIX_ENV="prod"
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/clinic_demo ./
USER nobody

# Migrations are NOT run here. Running them from the application container
# means every replica races to migrate on rollout. fly.toml's release_command
# runs them once per deploy instead:
#
#   [deploy]
#     release_command = "/app/bin/migrate"
#
# Seeding is manual, on purpose (it books a day of demo appointments):
#   fly ssh console -C "/app/bin/clinic_demo eval ClinicDemo.Release.seed()"
#
# See lib/clinic_demo/release.ex.
CMD ["/app/bin/server"]
