---
paths:
  - "scripts/**/*"
---

# MobiSSH Scripts

Key scripts (check `ls scripts/` before writing inline commands):
- `server-ctl.sh` -- local static/telemetry server lifecycle (not for user testing)
- `container-ctl.sh` -- production Docker container lifecycle
- `native-fast-gate.sh` -- the gate (rule tests, infra tests, analyze, flutter test)
- `test-infra.sh` -- the node:test infrastructure suite (`test/infra/`)
- `native-integration-suite.sh` -- on-emulator tests
- `gh-file-issue.sh` / `gh-ops.sh` -- GitHub operations
- `integrate-gate.sh` -- bot PR validation
- `delegate-*.sh` -- delegation
- `bot-branch.sh` -- bot branch lifecycle (create, commit, push, PR)
- `rescue-worktree.sh` -- extract stalled agent work safely
- `lib/repo-guard.sh` -- sourced by other scripts for CWD drift protection and safe worktree ops

## Project-specific conventions

- **Temp and log directories:**
  ```bash
  MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
  MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
  mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
  ```
- Emulator/adb helpers must NOT run as root/sudo.
