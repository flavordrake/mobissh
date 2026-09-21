# MobiSSH Code Style

- Avoid inline styles in HTML. Prefer CSS for all layout, appearance, themes, sizing.
- Use `tree` to discover file structure before creating any test or new component.
- `node_modules/` is gitignored. Install via `npm install` in `server/`.
- **There is no web build step.** The PWA's TypeScript sources were retired in #1205;
  `public/` is now served verbatim (the install page, its two scripts, the root
  redirect stub). Do not reintroduce a bundler or a `tsc` step without an issue.
- **Never bump localStorage keys to solve cache/staleness.** Config systems must support:
  default init, user reset (Settings button), schema migration (version inside the value,
  not the key), and corrupt data resilience (validation → fallback, no crash).
