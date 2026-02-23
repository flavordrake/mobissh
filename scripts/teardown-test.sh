#!/usr/bin/env bash
# scripts/teardown-test.sh
#
# Stops and removes the MobiSSH test container and cleans up the nginx
# location block added by scripts/test-release.sh.
#
# Usage:  sudo bash scripts/teardown-test.sh
#
# Configuration via environment variables (optional):
#   NGINX_CONF  Path to the nginx server-block config file
#               (default: /etc/nginx/sites-enabled/code-server)

set -euo pipefail

CONTAINER="mobissh-test"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-enabled/code-server}"
SNIPPET="/etc/nginx/snippets/mobissh-test.conf"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo bash $0" >&2
  exit 1
fi

# ── Stop and remove container ──────────────────────────────────────────────────
if docker inspect "$CONTAINER" &>/dev/null; then
  echo "Stopping and removing container: $CONTAINER"
  docker rm -f "$CONTAINER" >/dev/null
  echo "Container removed."
else
  echo "No container named '$CONTAINER' found — skipping."
fi

# ── Remove nginx snippet and include line ──────────────────────────────────────
if [[ -f "$SNIPPET" ]]; then
  rm -f "$SNIPPET"
  echo "Removed nginx snippet: $SNIPPET"
fi

if [[ -f "$NGINX_CONF" ]] && grep -q 'mobissh-test\.conf' "$NGINX_CONF"; then
  sed -i '/mobissh-test\.conf/d' "$NGINX_CONF"
  echo "Removed include line from $NGINX_CONF"

  if nginx -t 2>&1; then
    nginx -s reload
    echo "nginx reloaded — /ssh-test removed"
  else
    echo "Warning: nginx config test failed after cleanup. Check $NGINX_CONF manually." >&2
  fi
fi

echo "Done — test environment torn down."
