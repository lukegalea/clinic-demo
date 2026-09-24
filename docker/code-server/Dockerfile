# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT
#
# clinic-code-server — VS Code in the browser for this repository, carrying
# the SAME pinned toolchain as the clinic-elixir gate image so ElixirLS
# compiles the project with byte-identical versions (OTP 27.3.4.17 /
# Elixir 1.20.4).
#
# Base: ghcr.io/coder/code-server (Debian 13, uid 1000 = the host uid).
# Toolchain: copied from the local `elixir:1.20-otp-27` image (Debian 12;
# older-glibc binaries run fine on the newer base). No downloads, no drift:
# the toolchain is literally the gate image's.
#
# Build:  docker build -t clinic-code-server:1.0 docker/code-server
# Run:    scripts/dev-ide.sh  (flags, volumes, auth and port live there)

FROM elixir:1.20-otp-27 AS elixir-toolchain

FROM ghcr.io/coder/code-server:latest

USER root

# The whole /usr/local merge is deliberate: the official Elixir image
# installs Erlang and Elixir under /usr/local, and code-server keeps
# itself out of that prefix (it lives in /usr/lib/code-server).
COPY --from=elixir-toolchain /usr/local /usr/local

# git — ElixirLS and the gate tasks assume it (git deps, rebar).
# jq — the ash-agent/serena scripts' stdout is JSON.
# docker CLI — the `gate:*` tasks in .vscode/tasks.json talk to the host
#   daemon through the mounted socket. The socket is mounted at RUNTIME by
#   scripts/dev-ide.sh; this is only the client.
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends git jq ca-certificates curl; \
    (apt-get install -y --no-install-recommends docker-cli \
      || apt-get install -y --no-install-recommends docker.io); \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8

# Sanity gate: the build fails loudly if the toolchain did not survive the
# copy (wrong arch, stripped /usr/local, etc.).
RUN erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().' \
    && elixir --version | grep -q "Elixir 1.20.4"

USER coder
