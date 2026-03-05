# Code Style

- Avoid inline styles in HTML. Prefer CSS for all layout, appearance, themes, sizing.
- Don't use multiline text separators in logs, scripts, summaries, and reports (no `====`, no `----`). It's noise and wastes tokens.
- Use `tree` to discover file structure before creating any test or new component.
- `node_modules/` is gitignored. Install via `npm install` in `server/`.
- Build step is TypeScript compilation only. No heavy bundlers (webpack, vite) unless justified. Compiled output served from `public/`.
