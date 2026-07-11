#!/usr/bin/env bash
# scripts/lib/testsshd-fixture.sh — shared helpers for per-worktree test-sshd
# fixture teardown (#1049).
#
# Background: `docker compose -f docker-compose.test.yml up` derives its project
# name from the CWD's basename. Run from the main checkout that is `mobissh`
# (container `mobissh-test-sshd-1`, the canonical long-lived fixture). Run from
# an agent worktree (`.claude/worktrees/agent-<id>/`) it is `agent-<id>`
# (container `agent-<id>-test-sshd-1`) — and those orphaned for days after a
# worktree was deleted, which thrashed the PVE host (operator directive,
# agent-hub msg 64). The spawning script must guarantee teardown on exit.
#
# Source this from any script that composes up docker-compose.test.yml:
#   source "$(dirname "$0")/lib/testsshd-fixture.sh"
#
# Provides:
#   testsshd_compose_project — echo the compose project name docker compose
#                              would derive from $PWD
#   testsshd_fixture_down P  — `docker compose -p P down` the fixture, but ONLY
#                              for agent-* projects; refuses (no-op, exit 0) for
#                              anything else so the canonical fixture is safe
#
# Teardown mechanism map (#1049) — every spawn path is covered by ONE of:
#   EXIT trap (this lib): run-appium-tests.sh, run-emulator-tests.sh,
#     desktop-smoke.sh + native-connect-test.sh (teardown-if-spawned), and —
#     transitively — tests/emulator/sshd-fixture.js, whose compose-up lands in
#     the same project as its mandated wrappers (run-appium/run-emulator).
#   Age sweep (scripts/ci-reap.sh): test-sshd-up.sh fixtures, which
#     INTENTIONALLY outlive one script call (multi-test agent runs). The docker
#     Created timestamp is the age marker; the sweeper removes agent-* fixtures
#     older than CI_REAP_MAX_AGE_HOURS (default 6h).

# Echo the project name `docker compose` derives from $PWD: lowercased basename
# with characters outside [a-z0-9_-] removed and leading separators trimmed.
testsshd_compose_project() {
  basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g' -e 's/^[_-]*//'
}

# Down a per-worktree fixture project. Guarded: acts only on agent-* projects.
# Usage: testsshd_fixture_down <project> [compose-file]
testsshd_fixture_down() {
  local proj="${1:-}"
  local compose_file="${2:-docker-compose.test.yml}"
  case "$proj" in
    agent-*) ;;
    *)
      # Not a per-worktree fixture (e.g. canonical `mobissh` project) — leave it.
      return 0
      ;;
  esac
  echo "> testsshd-fixture: docker compose -p $proj down (#1049 teardown)"
  if ! docker compose -f "$compose_file" -p "$proj" down --remove-orphans; then
    # Compose file may be gone (worktree deleted mid-run) — remove the container directly.
    echo "! testsshd-fixture: compose down failed, falling back to docker rm -f ${proj}-test-sshd-1" >&2
    if ! docker rm -f "${proj}-test-sshd-1"; then
      echo "! testsshd-fixture: could not remove ${proj}-test-sshd-1 (ci-reap.sh will sweep it)" >&2
      return 1
    fi
  fi
}
