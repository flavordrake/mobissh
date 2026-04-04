#!/bin/sh
# MobiSSH production entrypoint
# Starts tailscaled, authenticates, sets up tailscale serve, then runs the app.
set -e

# Start tailscaled in the background with state persisted to /var/lib/tailscale
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
TSDPID=$!

# Wait for tailscaled socket
for i in $(seq 1 30); do
  [ -S /var/run/tailscale/tailscaled.sock ] && break
  sleep 0.5
done

if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
  echo "[entrypoint] tailscaled socket not found after 15s, exiting"
  exit 1
fi

# Authenticate (TS_AUTHKEY must be set for headless auth)
if [ -n "$TS_AUTHKEY" ]; then
  tailscale up --authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-mobissh}"
else
  # Already authenticated from persisted state, just bring it up
  tailscale up --hostname="${TS_HOSTNAME:-mobissh}"
fi

echo "[entrypoint] Tailscale is up: $(tailscale ip -4)"

# Serve the app via tailscale serve (HTTPS -> localhost:PORT)
# TS_SERVE_PORT: external HTTPS port (default 443). Set to e.g. 8765 to share
# the tailnet hostname with other services.
tailscale serve --bg --https "${TS_SERVE_PORT:-443}" http://localhost:${PORT:-8081}

echo "[entrypoint] tailscale serve configured, starting MobiSSH on port ${PORT:-8081}"

# Run the node app in foreground
exec node server/index.js
