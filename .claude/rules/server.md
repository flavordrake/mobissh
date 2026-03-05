# Server Management

## Production: Docker container with Tailscale

The production server runs as a Docker container (`mobissh-prod`) via `docker-compose.prod.yml`.
It includes Tailscale and serves via `tailscale serve` — no separate nginx needed.

- **Rebuild and deploy**: `docker compose -f docker-compose.prod.yml build && docker compose -f docker-compose.prod.yml up -d`
- **Check status**: `docker ps --filter name=mobissh-prod`
- **View logs**: `docker logs mobissh-prod --tail 50`
- **Verify code is current**: `docker exec mobissh-prod grep '<marker>' /app/public/app.css`
- Container must be rebuilt after code changes — it copies `public/` and `server/` at build time.
- The container handles its own Tailscale connection. User accesses via HTTPS on the Tailscale endpoint.

## Local server (legacy, headless tests only)

`scripts/server-ctl.sh` (start/stop/restart/ensure/status) manages a local Node.js process on port 8081.
This is used only by `scripts/test-headless.sh` and CI — NOT for user-facing testing.
Never raw `kill`, `lsof -t`, or `node server/index.js`.

## Key rules

- Before asking the user to test anything: rebuild the container, verify the change is in the image.
- `server-ctl.sh` is for headless Playwright tests only, not production.
- Server caches git hash at startup. Stale container = stale code.
- `Cache-Control: no-store` on all static responses and service worker network-first.
