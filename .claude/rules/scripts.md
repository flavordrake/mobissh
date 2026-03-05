---
paths:
  - "scripts/**/*"
---

# Scripts

- **Never prefix script calls with `bash`.** All scripts have shebangs and execute permissions. Call `scripts/foo.sh` not `bash scripts/foo.sh`.
- **Prefer existing scripts over raw commands.** Check `ls scripts/` before writing inline commands. Key scripts:
  - `server-ctl.sh` — server lifecycle
  - `test-*.sh` — test gates (typecheck, lint, unit, headless)
  - `run-appium-tests.sh` — emulator tests
  - `gh-file-issue.sh` / `gh-ops.sh` — GitHub operations
  - `integrate-gate.sh` — bot PR validation
  - `delegate-*.sh` — delegation
- **Timestamps in filenames use compact ISO-8601 with tz offset:** `date +%Y%m%dT%H%M%S%z` → `20260303T150827-0500`. Never use bare `%Y%m%d-%H%M%S`.
- Scripts log to `/tmp/<script-name>.log` via `exec > >(tee -a "$LOGFILE") 2>&1`.
- Never use `|| true` to swallow errors. Use `if ! cmd; then log "failed (reason)"; fi`.
- `scripts/setup-appium.sh` must NOT run as root/sudo.
