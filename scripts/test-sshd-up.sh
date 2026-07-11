#!/usr/bin/env bash
# scripts/test-sshd-up.sh — bring up the test-sshd container on the shared
# `mobissh` docker network and join THIS container to it, so emulator/headless
# integration tests can reach `test-sshd:22`. Idempotent; safe to re-run.
#
# Needed after a host/process restart (the container + network join die with it).
# Mirrors what tests/emulator/sshd-fixture.js does, for manual/orchestrator use.
#
# TEARDOWN (#1049): run from an AGENT WORKTREE, compose names the fixture
# agent-<worktree-id>-test-sshd-1. That fixture intentionally OUTLIVES this
# script call (multi-test agent runs re-use it), so there is no EXIT trap here;
# instead scripts/ci-reap.sh removes agent-* fixtures older than
# CI_REAP_MAX_AGE_HOURS (6h) using the container's docker Created timestamp as
# the age marker. Run scripts (native-connect-test.sh, desktop-smoke.sh) that
# call this on-demand DO tear down what they spawned, on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.test.yml"
NETWORK="mobissh"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "! test-sshd-up: $COMPOSE_FILE not found at repo root" >&2
  exit 2
fi

# 1. Ensure the shared external network exists (compose files use external:true).
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "> creating docker network $NETWORK"
  docker network create "$NETWORK"
else
  echo "> docker network $NETWORK present"
fi

# 2. Bring up the test sshd container.
echo "> docker compose up -d ($COMPOSE_FILE)"
docker compose -f "$COMPOSE_FILE" up -d

# 3. Join THIS container to the network (Docker DNS — no port mapping here).
SELF="$(hostname)"
if docker network inspect "$NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "$SELF"; then
  echo "> this container ($SELF) already on $NETWORK"
else
  echo "> joining this container ($SELF) to $NETWORK"
  if ! docker network connect "$NETWORK" "$SELF"; then
    echo "! test-sshd-up: could not join $SELF to $NETWORK (may already be joined under another id)" >&2
  fi
fi

echo "+ test-sshd up; reachable as test-sshd:22 on $NETWORK"
docker ps --filter "name=test-sshd" --format '  {{.Names}} {{.Status}}'
