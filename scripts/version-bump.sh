#!/usr/bin/env bash
# scripts/version-bump.sh
#
# Bump version in all touchpoints: server/package.json + public/sw.js cache name.
# Usage: scripts/version-bump.sh <new-version>
# Example: scripts/version-bump.sh 0.7.0

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <new-version>" >&2
  echo "Example: $0 0.7.0" >&2
  exit 1
fi

NEW_VERSION="$1"

# Validate version format (semver or semver-prerelease)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
  echo "Error: invalid version format '$NEW_VERSION'. Expected semver (e.g., 0.7.0 or 0.7.0-rc1)." >&2
  exit 1
fi

# 1. Bump server/package.json
PKG="$REPO_ROOT/server/package.json"
OLD_VERSION=$(node -e "process.stdout.write(require('$PKG').version)")
echo "server/package.json: $OLD_VERSION -> $NEW_VERSION"
node -e "
  const fs = require('fs');
  const pkg = JSON.parse(fs.readFileSync('$PKG', 'utf8'));
  pkg.version = '$NEW_VERSION';
  fs.writeFileSync('$PKG', JSON.stringify(pkg, null, 2) + '\n');
"

# 2. Bump public/sw.js CACHE_NAME (monotonic integer suffix)
SW="$REPO_ROOT/public/sw.js"
OLD_CACHE=$(grep -oP "CACHE_NAME = 'mobissh-v\K[0-9]+" "$SW")
NEW_CACHE=$((OLD_CACHE + 1))
echo "public/sw.js: mobissh-v$OLD_CACHE -> mobissh-v$NEW_CACHE"
sed -i "s/CACHE_NAME = 'mobissh-v${OLD_CACHE}'/CACHE_NAME = 'mobissh-v${NEW_CACHE}'/" "$SW"

# 3. Summary
echo ""
echo "Version bumped to $NEW_VERSION (SW cache v$NEW_CACHE)"
echo "Files changed:"
echo "  server/package.json"
echo "  public/sw.js"
echo ""
echo "Next: git add server/package.json public/sw.js && git commit -m 'release: v$NEW_VERSION'"
