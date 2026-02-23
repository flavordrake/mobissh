#!/usr/bin/env bash
# scripts/test-release.sh
#
# Builds the MobiSSH Docker image from the current git HEAD and runs it as a
# pre-release test endpoint, accessible over nginx at /ssh-test/.
#
# Requirements:
#   - Docker
#   - nginx with an existing HTTPS server block at NGINX_CONF
#   - Run as root (needs to write nginx config and reload nginx)
#
# Usage:  sudo bash scripts/test-release.sh
# Teardown: sudo bash scripts/teardown-test.sh
#
# Configuration via environment variables (optional):
#   NGINX_CONF  Path to the nginx server-block config file
#               (default: /etc/nginx/sites-enabled/code-server)
#   PORT        Container port (default: 8082)
#   ROUTE       URL path prefix (default: /ssh-test)

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
IMAGE="mobissh-test"
CONTAINER="mobissh-test"
PORT="${PORT:-8082}"
ROUTE="${ROUTE:-/ssh-test}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-enabled/code-server}"
SNIPPET="/etc/nginx/snippets/mobissh-test.conf"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo bash $0" >&2
  exit 1
fi

# ── Stop any existing test container ──────────────────────────────────────────
if docker inspect "$CONTAINER" &>/dev/null; then
  echo "Removing previous test container..."
  docker rm -f "$CONTAINER" >/dev/null
fi

# ── Build Docker image from current HEAD ──────────────────────────────────────
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
echo "Building $IMAGE:$HEAD_SHA from current HEAD..."
docker build -t "$IMAGE:$HEAD_SHA" -t "$IMAGE:latest" "$REPO_ROOT"

# ── Start container ────────────────────────────────────────────────────────────
# Port is bound to 127.0.0.1 only — nginx is the public TLS entry point.
# Container is stateless (no volumes) for clean test isolation.
echo "Starting container on 127.0.0.1:${PORT}..."
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -p "127.0.0.1:${PORT}:${PORT}" \
  -e "PORT=${PORT}" \
  -e "BASE_PATH=${ROUTE}" \
  "$IMAGE:latest"

# ── Configure nginx ────────────────────────────────────────────────────────────
if [[ ! -f "$NGINX_CONF" ]]; then
  echo ""
  echo "Warning: $NGINX_CONF not found — skipping nginx setup." >&2
  echo "Manually add a location block proxying ${ROUTE}/ → http://127.0.0.1:${PORT}/" >&2
else
  mkdir -p /etc/nginx/snippets

  # Write the location block to a dedicated snippet file so teardown-test.sh
  # can cleanly remove it by deleting the file.
  cat > "$SNIPPET" << NGINX_EOF
# MobiSSH pre-release test — managed by scripts/test-release.sh
# Remove with: sudo bash scripts/teardown-test.sh

location = ${ROUTE} {
    return 301 ${ROUTE}/;
}

location ${ROUTE} {
    rewrite ^${ROUTE}(/.*)$ \$1 break;
    rewrite ^${ROUTE}$ / break;
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection upgrade;
    proxy_set_header Accept-Encoding gzip;
}
NGINX_EOF

  if ! grep -q 'mobissh-test.conf' "$NGINX_CONF"; then
    # Insert the include directive before the last closing brace of the server block.
    LAST_BRACE=$(grep -n '^}' "$NGINX_CONF" | tail -1 | cut -d: -f1)
    sed -i "${LAST_BRACE}i\\    include /etc/nginx/snippets/mobissh-test.conf;" "$NGINX_CONF"
  fi

  if nginx -t 2>&1; then
    nginx -s reload
    echo "nginx reloaded — ${ROUTE} is now active"
  else
    echo "Error: nginx config test failed. Check $NGINX_CONF manually." >&2
    exit 1
  fi
fi

# ── Print test URL ─────────────────────────────────────────────────────────────
SERVER_NAME=$(grep -m1 'server_name' "$NGINX_CONF" 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "<tailscale-host>")
echo ""
echo "════════════════════════════════════════════════"
echo "  MobiSSH pre-release test is running"
echo "  Build: ${HEAD_SHA}"
echo "  URL:   https://${SERVER_NAME}${ROUTE}/"
echo ""
echo "  Tear down: sudo bash scripts/teardown-test.sh"
echo "════════════════════════════════════════════════"
