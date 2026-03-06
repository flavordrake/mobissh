# Server Management

## Production: Docker container with Tailscale

The production server runs as a Docker container (`mobissh-prod`) via `docker-compose.prod.yml`.
It includes Tailscale and serves via `tailscale serve` — no separate nginx needed.

- **Lifecycle**: `scripts/container-ctl.sh {start|stop|restart|status|ensure}`
- **Rebuild and deploy**: `scripts/container-ctl.sh restart` (builds image, starts container, verifies version)
- **Check status**: `scripts/container-ctl.sh status` (health + code-currency check)
- **Ensure current**: `scripts/container-ctl.sh ensure` (idempotent: rebuilds only if stale)
- **View logs**: `docker logs mobissh-prod --tail 50`
- **Initial deploy with Tailscale auth**: `scripts/deploy-prod.sh` (handles auth key)
- Container must be rebuilt after code changes — it copies `public/` and `server/` at build time.
- Git hash is baked into the image at build time (`/app/.git-hash`). No git required in container.
- The container handles its own Tailscale connection. User accesses via HTTPS on the Tailscale endpoint.

## Local server (legacy, headless tests only)

`scripts/server-ctl.sh` (start/stop/restart/ensure/status) manages a local Node.js process on port 8081.
This is used only by `scripts/test-headless.sh` and CI — NOT for user-facing testing.
Never raw `kill`, `lsof -t`, or `node server/index.js`.

## Key rules

- Before asking the user to test anything: `scripts/container-ctl.sh ensure`.
- `server-ctl.sh` is for headless Playwright tests only, not production.
- Git hash is baked at build time. Stale container = stale code. Use `container-ctl.sh status` to check.
- `Cache-Control: no-store` on all static responses and service worker network-first.
