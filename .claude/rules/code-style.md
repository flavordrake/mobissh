# MobiSSH Code Style

- Avoid inline styles in HTML. Prefer CSS for all layout, appearance, themes, sizing.
- Use `tree` to discover file structure before creating any test or new component.
- `node_modules/` is gitignored. Install via `npm install` in `server/`.
- Build step is TypeScript compilation only. No heavy bundlers (webpack, vite) unless justified.
- **Compiled JS (`public/app.js`, `public/modules/*.js`) is gitignored.** Do NOT commit compiled output. It is built automatically by Docker (`Dockerfile`), `scripts/server-ctl.sh`, and `scripts/test-headless.sh`. Run `npx tsc` locally if needed for development.
- **`public/sw.js` cache hash is build-derived — do NOT commit hash changes.** `container-ctl.sh` modifies `sw.js` in-place with a content hash (known design flaw #237). If `sw.js` shows as dirty with only a `CACHE_NAME` change, restore it: `git checkout -- public/sw.js`.
- **Never bump localStorage keys to solve cache/staleness.** Config systems must support:
  default init, user reset (Settings button), schema migration (version inside the value,
  not the key), and corrupt data resilience (validation → fallback, no crash).
