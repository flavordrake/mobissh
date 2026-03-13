---
name: server-management
description: This skill should be used when the user asks to "start the server", "restart the server", "check server status", "is the server running", "server health", "server version", "rebuild container", or when the agent needs to ensure the server is running before testing. Use proactively before any manual or emulator testing, before asking the user to verify something in the browser. Also use when the user reports stale behavior or says "it's not showing my changes".
version: 0.2.0
---

# Server Management

MobiSSH runs as a Docker container in production. Code changes require a container rebuild.

## Production: Docker container (`mobissh-prod`)

The production server runs via `docker-compose.prod.yml` with built-in Tailscale.
The container copies `public/` and `server/` at build time -- it does NOT hot-reload.

### Commands

```bash
# Rebuild and deploy (after code changes)
scripts/container-ctl.sh restart

# Check status (health + code-currency check)
scripts/container-ctl.sh status

# Ensure current (idempotent: rebuilds only if stale)
scripts/container-ctl.sh ensure

# View logs
docker logs mobissh-prod --tail 50

# Verify code is current
docker exec mobissh-prod grep '<marker>' /app/public/app.css

# Shell into container
docker exec -it mobissh-prod sh
```

### "My changes aren't showing"

1. Did you run `npx tsc` to compile TypeScript? (`tsc --noEmit` only type-checks)
2. Did you rebuild the container? (`scripts/container-ctl.sh restart`)
3. Verify: `docker exec mobissh-prod grep '<your change>' /app/public/modules/<file>.js`

### TypeScript workflow for container

1. Edit `src/modules/*.ts`
2. Run `npx tsc` (NOT `--noEmit`)
3. Rebuild container: `scripts/container-ctl.sh restart`
4. Verify: `docker exec mobissh-prod grep '<marker>' /app/public/modules/<file>.js`

## Local server (headless tests only)

`scripts/server-ctl.sh` manages a local Node.js process on port 8081 for headless Playwright tests.
This is NOT used for user-facing testing.

```bash
scripts/server-ctl.sh ensure    # start or restart until healthy at HEAD
scripts/server-ctl.sh status    # health check + version gate
scripts/server-ctl.sh start     # start if not running
scripts/server-ctl.sh stop      # stop server
scripts/server-ctl.sh restart   # force restart
```

`scripts/test-headless.sh` handles server lifecycle automatically via Playwright's `webServer` config.

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | 8081 | Server listen port |
| `TS_AUTHKEY` | (none) | Tailscale auth key for container |
| `TS_HOSTNAME` | mobissh | Tailscale hostname |
| `TS_SERVE` | 1 | Enable tailscale serve (skips auth in container) |

## Test sshd container

A separate Docker Compose file (`docker-compose.test.yml`) runs an sshd container for testing:
```bash
docker compose -f docker-compose.test.yml up -d test-sshd   # start test sshd on port 2222
```

Note: test sshd is a simple container with no lifecycle script — raw `docker compose` is acceptable here.
