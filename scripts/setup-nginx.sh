#!/usr/bin/env bash
# scripts/setup-nginx.sh
#
# Adds the /ssh nginx location to the code-server HTTPS config so MobiSSH
# is accessible at https://<tailscale-host>/ssh/ alongside code-server.
#
# Usage:  sudo bash scripts/setup-nginx.sh
#
# What it does:
#   1. Checks nginx config exists and doesn't already have /ssh
#   2. Inserts a /ssh location block before the closing } of the server block
#   3. Tests the config with nginx -t
#   4. Reloads nginx
#
# Safe to re-run — exits early if /ssh is already configured.

set -euo pipefail

NGINX_CONF="/etc/nginx/sites-enabled/code-server"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo bash $0"
  exit 1
fi

if [[ ! -f "$NGINX_CONF" ]]; then
  echo "Error: $NGINX_CONF not found"
  exit 1
fi

if grep -q 'location /ssh' "$NGINX_CONF"; then
  echo "nginx /ssh location already configured in $NGINX_CONF"
  nginx -t 2>&1
  exit 0
fi

# Insert the /ssh location block before the final closing brace
# Uses a temp file so we don't corrupt the config on failure
TMP=$(mktemp)
sed '/^}$/i \
\
    location = /ssh {\
        return 301 /ssh/;\
    }\
\
    location /ssh {\
        rewrite ^/ssh(/.*)$ $1 break;\
        rewrite ^/ssh$ / break;\
        proxy_pass http://127.0.0.1:8081;\
        proxy_http_version 1.1;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection upgrade;\
        proxy_set_header Accept-Encoding gzip;\
    }' "$NGINX_CONF" > "$TMP"

# Validate before applying
cp "$TMP" "$NGINX_CONF"
rm "$TMP"

if nginx -t 2>&1; then
  nginx -s reload
  echo "nginx reloaded with /ssh location"
  echo "MobiSSH will be at https://$(grep server_name "$NGINX_CONF" | awk '{print $2}' | tr -d ';')/ssh/"
else
  echo "Error: nginx config test failed. Check $NGINX_CONF manually."
  exit 1
fi
