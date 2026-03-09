# Code Style

- Avoid inline styles in HTML. Prefer CSS for all layout, appearance, themes, sizing.
- Don't use multiline text separators in logs, scripts, summaries, and reports (no `====`, no `----`). It's noise and wastes tokens.
- Use `tree` to discover file structure before creating any test or new component.
- `node_modules/` is gitignored. Install via `npm install` in `server/`.
- Build step is TypeScript compilation only. No heavy bundlers (webpack, vite) unless justified.
- **Compiled JS (`public/modules/*.js`) is gitignored.** Do NOT commit compiled output. It is built automatically by Docker (`Dockerfile`), `scripts/server-ctl.sh`, and `scripts/test-headless.sh`. Run `npx tsc` locally if needed for development.
- **No compound `&&` chains.** Use wrapper scripts, not `&&`-chained raw commands. Chained commands cause false positive failures (e.g., local branch delete fails but remote merge succeeded, exit 1 blocks downstream steps).
  - Merge + close: `scripts/gh-ops.sh integrate <PR> <issue>`
  - Delegate setup: `scripts/gh-ops.sh delegate <issue> [--label L]`
  - Labels: `scripts/gh-ops.sh labels <issue> --add X --rm Y`
  - Server: `scripts/container-ctl.sh ensure` (not raw docker compose chains)
  - Fast gate: `scripts/test-fast-gate.sh` (not `test-typecheck.sh && test-lint.sh && test-unit.sh`)
- **Never use raw `gh` commands.** Always use `scripts/gh-ops.sh` or `scripts/gh-file-issue.sh`.
  Raw `gh` calls bypass error handling, audit logging, and hook notifications.
  If `gh-ops.sh` doesn't have a subcommand for what you need, add one — don't work around it.
  This applies to ALL contexts: main session, agent prompts, skill docs, and inline Bash calls.
