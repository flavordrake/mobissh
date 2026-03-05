---
paths:
  - "scripts/**/*"
---

# Scripts

- **Never prefix script calls with `bash`.** All scripts have shebangs and execute permissions. Call `scripts/foo.sh` not `bash scripts/foo.sh`.
- **Prefer existing scripts over raw commands.** Check `ls scripts/` before writing inline commands. Key scripts:
  - `server-ctl.sh` -- server lifecycle
  - `test-*.sh` -- test gates (typecheck, lint, unit, headless)
  - `run-appium-tests.sh` -- emulator tests
  - `gh-file-issue.sh` / `gh-ops.sh` -- GitHub operations
  - `integrate-gate.sh` -- bot PR validation
  - `delegate-*.sh` -- delegation
- **Timestamps in filenames use compact ISO-8601 with tz offset:** `date +%Y%m%dT%H%M%S%z` -> `20260303T150827-0500`. Never use bare `%Y%m%d-%H%M%S`.
- **Temp and log directories:** Every script defines these two variables near the top (after `set -euo pipefail`) and creates the directories before use:
  ```bash
  MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
  MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
  mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
  ```
  - Ephemeral temp files (JSON data, branch lists, PID files, intermediate files): `$MOBISSH_TMPDIR/`
  - Log files and diagnostic artifacts: `$MOBISSH_LOGDIR/`
  - Do NOT use `TMPDIR` as the variable name — it conflicts with the system `TMPDIR` used by `mktemp` and other tools.
  - Scripts log via `exec > >(tee -a "$LOGFILE") 2>&1` where `LOGFILE="${MOBISSH_LOGDIR}/<script-name>.log"`.
- Never use `|| true` to swallow errors. Use `if ! cmd; then log "failed (reason)"; fi`.
- `scripts/setup-appium.sh` must NOT run as root/sudo.
