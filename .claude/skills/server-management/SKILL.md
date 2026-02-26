---
name: server-management
description: This skill should be used when the user asks to "start the server", "restart the server", "check server status", "is the server running", "server health", "server version", or when the agent needs to ensure the dev server is running before testing. Use proactively before any manual or emulator testing, before asking the user to verify something in the browser, and before any curl/fetch against localhost. Also use when the user reports stale behavior or says "it's not showing my changes".
version: 0.1.0
---

# Server Management

MobiSSH caches the git hash at startup. A running server will serve stale code until restarted. This is the #1 cause of "my changes aren't showing" confusion.

## The Rule

Before ANY of these actions, run `bash scripts/server-ctl.sh ensure`:
- Asking the user to test in their browser
- Running emulator tests (`run-emulator-tests.sh` does this automatically)
- Curling localhost to verify behavior
- Checking production via the Tailscale endpoint

`ensure` is idempotent. If the server is already healthy and at HEAD, it's a no-op. If it's stale or down, it restarts automatically.

## Commands

```bash
bash scripts/server-ctl.sh ensure    # start or restart until healthy at HEAD
bash scripts/server-ctl.sh status    # health check + version gate
bash scripts/server-ctl.sh start     # start if not running, restart if stale
bash scripts/server-ctl.sh stop      # stop server
bash scripts/server-ctl.sh restart   # force restart
```

Or via npm:
```bash
npm run server:ensure
npm run server:status
npm run server -- restart
```

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | 8081 | Server listen port |
| `BASE_PATH` | (none) | URL prefix (e.g. `/ssh` for nginx proxy) |
| `HEALTH_TIMEOUT` | 10 | Seconds to wait for health after start |

## How It Works

1. **Health check**: `GET http://localhost:$PORT/` must return HTTP 200
2. **Version gate**: Response must contain `<meta name="app-version" content="...:$GIT_HASH">` where `$GIT_HASH` matches `git rev-parse --short HEAD`
3. **Auto-restart**: If healthy but stale, stops the old process and starts a new one
4. **PID tracking**: Writes PID to `/tmp/mobissh-server-$PORT.pid`, falls back to `lsof` if pidfile is stale
5. **Logging**: Server stdout/stderr goes to `/tmp/mobissh-server-$PORT.log`

## Version Mismatch Scenarios

The server captures `git rev-parse --short HEAD` at startup and injects it into every HTML response as `<meta name="app-version">`. This means:

- **New commit but no restart**: Server serves old hash. `status` shows `STALE`. `ensure` restarts.
- **Amended commit**: Hash changes even though "same" commit. `ensure` catches it.
- **Detached HEAD / branch switch**: New hash. `ensure` catches it.
- **Uncommitted changes**: Hash stays the same (it's HEAD, not working tree). The script doesn't detect uncommitted changes — only committed code.

## Integration with Test Runners

`scripts/run-emulator-tests.sh` calls `server-ctl.sh ensure` as its first step. This guarantees emulator tests always run against the latest committed code.

For headless Playwright tests, the `playwright.config.js` `webServer` option handles server lifecycle independently (Playwright starts/stops its own process per run). The two don't conflict because they use different ports.

## Production Endpoint

The production server runs behind nginx at `https://raserver.tailbe5094.ts.net/ssh/`. To verify it:

```bash
curl -sf https://raserver.tailbe5094.ts.net/ssh/ | grep -oP 'app-version.*?content="[^"]*"'
```

If production is stale, the server process needs restarting on the Tailscale host. `server-ctl.sh` only manages the local dev server.

## Troubleshooting

**"Server failed to become healthy within 10s"**: Check `/tmp/mobissh-server-$PORT.log`. Common causes: port already in use by another process, missing `node_modules/` (run `cd server && npm install`), syntax error in server code.

**PID exists but server not healthy**: The process started but is crashing or hanging. Check the log file. Kill it manually with `bash scripts/server-ctl.sh stop` and investigate.

**Port conflict**: Another process holds the port. Find it with `lsof -ti tcp:8081` and decide whether to kill it or use a different port.
