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

# 2. Bring up the test sshd container, DERIVED FROM THE CURRENT DOCKERFILE.
#
# #1187/#1101 G0: plain `up -d` reuses whatever image is already tagged with this
# compose project's name, however old. The canonical fixture ran a two-month-old
# image with `AllowTcpForwarding no` — it predates #1047 — for six weeks, so every
# test opening a direct-tcpip channel died `administratively prohibited` deep
# inside the test, reading exactly like a product bug. `--build` is a cache hit
# (~1s) when the Dockerfile has not changed, and compose recreates the container
# when the image id moves, so the fixture can never outlive the code it serves.
echo "> docker compose up -d --build ($COMPOSE_FILE)"
if ! docker compose -f "$COMPOSE_FILE" up -d --build; then
  # A build can fail for reasons that have nothing to do with the fixture (the
  # alpine CDN is unreachable from inside the build container on some days,
  # #1187). Fall back to the cached image — but then VERIFY it is current and
  # fail LOUD if it is not, rather than silently serving a stale bastion.
  echo "! test-sshd-up: build failed — falling back to the CACHED image" >&2
  docker compose -f "$COMPOSE_FILE" up -d
  source "scripts/lib/testsshd-fixture.sh"
  PROJECT="$(testsshd_compose_project)"
  if ! docker exec "${PROJECT}-test-sshd-1" \
      grep -q '^AllowTcpForwarding local' /etc/ssh/sshd_config; then
    echo "! test-sshd-up: the cached fixture ${PROJECT}-test-sshd-1 is STALE" >&2
    echo "  (no 'AllowTcpForwarding local' — it predates #1047). Port-forward and" >&2
    echo "  jump-host tests would fail as if the product were broken. Fix the" >&2
    echo "  build (#1187) or tag a current image into ${PROJECT}-test-sshd:latest." >&2
    exit 2
  fi
  echo "> cached fixture verified current (AllowTcpForwarding local)"
fi

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
