#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT
#
# clinic-ide — code-server (VS Code in the browser) for this repository.
#
#   scripts/dev-ide.sh build   # build clinic-code-server:1.0
#   scripts/dev-ide.sh start   # (re)create the container on :8444
#   scripts/dev-ide.sh stop
#   scripts/dev-ide.sh extensions   # install the .vscode list, non-interactive
#
# Access + credentials: .dev-access in the repository root (gitignored —
# never commit it). Summary: http://docke:8444 (tailnet), password in
# .dev-access.

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=clinic-code-server:1.0
CONTAINER=clinic-ide
PORT=8444
REPO="$(pwd)"

case "${1:-start}" in
  build)
    docker build -t "$IMAGE" docker/code-server
    ;;

  stop)
    docker rm -f "$CONTAINER"
    ;;

  start)
    if [ ! -f .dev-access ]; then
      echo "refusing to start: .dev-access is missing." >&2
      echo "Create it (see .dev-access.template) — it carries the IDE password." >&2
      exit 1
    fi
    # HASHED_PASSWORD is sha256 hex of the plaintext; .dev-access documents it.
    HASHED_PASSWORD="$(sed -n 's/^HASHED_PASSWORD=//p' .dev-access | tail -1 | tr -d '\"' | tr -d '[:space:]')"
    if [ -z "$HASHED_PASSWORD" ]; then
      echo "refusing to start: .dev-access has no HASHED_PASSWORD line." >&2
      exit 1
    fi

    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    # The docker socket is root:docker (host gid below); the IDE runs as the
    # host uid, so it needs that gid supplementary to use the gate tasks.
    DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
    # --network host          : reaches the dev server (:4000), Postgres (:5432)
    #                           and the ash_agent daemon (:4100) as localhost.
    # repo at /w              : the canonical path — the app container mounts
    #                           the same tree at /w; _build paths stay true.
    # clinic-ide-home         : persistent /home/coder — settings, extensions,
    #                           opencode. Survives container recreation.
    # docker.sock             : the gate:* tasks manage containers from the IDE.
    # -u 1000:1000            : the host uid — files the IDE writes are the
    #                           host user's, never root's.
    docker run -d --name "$CONTAINER" \
      --network host \
      --restart unless-stopped \
      --user 1000:1000 \
      --group-add "$DOCKER_GID" \
      -e HOME=/home/coder \
      -e HASHED_PASSWORD="$HASHED_PASSWORD" \
      -v "${REPO}:/w" \
      -v clinic-ide-home:/home/coder \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -w /w \
      "$IMAGE" \
      code-server --bind-addr "0.0.0.0:${PORT}" --auth password /w

    echo
    echo "clinic-ide up: http://docke:${PORT}  (password: see .dev-access)"
    echo "Next: scripts/dev-ide.sh extensions"
    ;;

  extensions)
    # The .vscode/extensions.json list, in code-server's open-vsx spellings.
    # ElixirLS is elixir-lsp.elixir-ls here (Marketplace ID JakeBecker.elixir-ls).
    for ext in \
      elixir-lsp.elixir-ls \
      ketupia.ash-studio \
      bierner.markdown-mermaid \
      usernamehw.errorlens \
      eamodio.gitlens \
      redhat.vscode-yaml \
      tamasfe.even-better-toml \
      ms-azuretools.vscode-docker; do
      echo "-- $ext"
      docker exec -u 1000:1000 -e HOME=/home/coder "$CONTAINER" \
        code-server --install-extension "$ext" --force
    done
    docker exec -u 1000:1000 "$CONTAINER" code-server --list-extensions
    ;;

  *)
    echo "usage: $0 {build|start|stop|extensions}" >&2
    exit 2
    ;;
esac
