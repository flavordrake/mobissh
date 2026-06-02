#!/usr/bin/env bash
# scripts/integration-required.sh — exit 0 if a changeset touches
# integration-SENSITIVE native code, meaning the on-emulator integration suite
# (native-integration-suite.sh) MUST gate it before merge (#589).
#
# The fast unit gate EXCLUDES the integration suite (it can't boot an emulator),
# so changes to the session state machine / connect / reconnect / SFTP / IPC can
# ship green-but-broken (the #539/#546/#547 class: passed headless, broke on
# device). This detector lets `gh-ops.sh integrate` refuse to merge such a PR
# unless the suite was actually run (--integration-verified).
#
# Usage:
#   integration-required.sh --pr <PR_NUM>   # uses `gh pr view` file list
#   <file-list-on-stdin> | integration-required.sh --stdin
#
# Exit 0 = integration suite REQUIRED (a sensitive path changed).
# Exit 1 = not required (UI-only / docs / tests / scripts).

set -euo pipefail

# Paths whose changes can only be validated on a real connect (state machine,
# transport, gateway/IPC, session lifecycle, SFTP). Keep this list tight so
# UI-only PRs are NOT blocked.
SENSITIVE_RE='^native/lib/(services/|ssh/|state/(sessions|connection_providers|keepalive_providers|terminal_providers|lifecycle_providers|session_host_providers)|sftp/)'

list_files() {
  case "${1:-}" in
    --pr)
      [ -n "${2:-}" ] || { echo "integration-required: --pr needs a PR number" >&2; exit 2; }
      gh pr view "$2" --json files --jq '.files[].path'
      ;;
    --stdin) cat ;;
    *) echo "Usage: integration-required.sh --pr <N> | --stdin" >&2; exit 2 ;;
  esac
}

# grep exits 1 on no match (set -e safe via the if).
if list_files "$@" | grep -qE "$SENSITIVE_RE"; then
  exit 0
fi
exit 1
