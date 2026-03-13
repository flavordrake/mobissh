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

## Docker networking

This dev environment runs inside a sibling Docker container (`fd-dev`). All containers
share the Docker daemon — they are siblings, not nested. There is no `docker-proxy` binary,
so **port mapping (`-p`) does not work**. Containers must communicate via Docker DNS on a
shared bridge network named `mobissh`.

- Never use `localhost:PORT` to reach sibling containers. Use Docker DNS names (`test-sshd`, `mobissh-prod`).
- Scripts auto-create the network and join this container: `docker network create mobissh` + `docker network connect`.
- Both compose files use `networks: mobissh: external: true`.

## Key rules

- Before asking the user to test anything: `scripts/container-ctl.sh ensure`.
- `server-ctl.sh` is for headless Playwright tests only, not production.
- Git hash is baked at build time. Stale container = stale code. Use `container-ctl.sh status` to check.
- `Cache-Control: no-store` on all static responses and service worker network-first.
- Never use `localhost` to reach Docker containers. Use Docker DNS (`test-sshd:22`, not `localhost:2222`).
