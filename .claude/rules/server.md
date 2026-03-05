# Server Management

- **Always use `scripts/server-ctl.sh`** (start/stop/restart/ensure/status). Never raw `kill`, `lsof -t`, or `node server/index.js`.
- Before asking the user to test anything: `scripts/server-ctl.sh restart`, verify version/hash matches HEAD.
- Server caches git hash at startup. Stale process = stale hash.
- Always curl the production endpoint `https://raserver.tailbe5094.ts.net/ssh/` to confirm it's up. User hits HTTPS via nginx, not localhost:8081.
- Single port 8081 for static files + WS bridge. nginx proxies HTTPS on the Tailscale endpoint.
