#!/usr/bin/env bash
# scripts/integrate-compile.sh — Pull main, compile TypeScript, commit compiled JS if changed
#
# Usage:
#   scripts/integrate-compile.sh
#
# Pulls main, runs npx tsc, commits compiled JS output if anything changed.

set -euo pipefail

LOGFILE="/tmp/integrate-compile.log"

cd "$(dirname "$0")/.."

log() { echo "> $*" >&2; echo "> $*" >> "$LOGFILE"; }
ok()  { echo "+ $*" >&2; echo "+ $*" >> "$LOGFILE"; }
err() { echo "! $*" >&2; echo "! $*" >> "$LOGFILE"; }

log "integrate-compile: pulling main and compiling TS"

# Switch to main and pull latest
git checkout main
git pull

# Compile TypeScript
log "Running npx tsc..."
if ! npx tsc; then
  err "TypeScript compilation failed"
  exit 1
fi
ok "tsc: pass"

# Check for compiled JS changes in public/
changed=$(git diff --name-only public/)

if [ -z "$changed" ]; then
  echo "No compiled JS changes"
  exit 0
fi

log "Changed files:"
echo "$changed" | while read -r f; do log "  $f"; done

# Stage and commit compiled output
git add public/
git commit -m "$(cat <<'EOF'
chore: compile TS output for merged bot PRs

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"

git push
ok "Pushed compiled JS to main"
echo "Committed compiled JS: $(echo "$changed" | wc -l | tr -d ' ') file(s) changed"
