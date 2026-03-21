#!/usr/bin/env bash
# scripts/security-audit.sh — Standalone security audit
#
# Runs semgrep (static), gemini (AI), codex (AI) against the codebase.
# Diffs findings against accepted.json to surface only NEW issues.
#
# Usage:
#   scripts/security-audit.sh                  Run full audit
#   scripts/security-audit.sh --semgrep-only   Run semgrep only (fast)
#
# Output: test-history/security/<timestamp>/
# Exit: 0 = no new critical/high findings, 1 = new findings need review

set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/security-audit.log"
exec > >(tee -a "$LOGFILE") 2>&1

TIMESTAMP=$(date +%Y%m%dT%H%M%S%z)
AUDIT_DIR="test-history/security/${TIMESTAMP}"
ACCEPTED_FILE="test-history/security/accepted.json"
SEMGREP_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --semgrep-only) SEMGREP_ONLY=true; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$AUDIT_DIR"

log() { echo "> $*"; }
ok()  { echo "+ $*"; }
err() { echo "! $*" >&2; }

# Ensure accepted findings file exists
if [ ! -f "$ACCEPTED_FILE" ]; then
  echo '[]' > "$ACCEPTED_FILE"
fi

NEW_FINDINGS=0

# ── Gate 1: Semgrep ──────────────────────────────────────────────────────────

log "Running semgrep scan..."
if command -v semgrep &>/dev/null; then
  semgrep scan --config auto --json --quiet src/ server/ public/ \
    --max-target-bytes 500000 --timeout 30 \
    > "${AUDIT_DIR}/semgrep-raw.json" 2>/dev/null || true

  # Extract findings and diff against accepted
  node -e "
    const fs = require('fs');
    const raw = JSON.parse(fs.readFileSync('${AUDIT_DIR}/semgrep-raw.json', 'utf8'));
    const accepted = JSON.parse(fs.readFileSync('${ACCEPTED_FILE}', 'utf8'));
    // Match on check_id + path (without line number — lines shift on edits)
    const acceptedIds = new Set(accepted.map(a => a.check_id + ':' + a.path));

    const results = (raw.results || []).map(r => ({
      check_id: r.check_id,
      path: r.path,
      line: r.start?.line,
      severity: r.extra?.severity || 'UNKNOWN',
      message: r.extra?.message || '',
      fingerprint: r.check_id + ':' + r.path
    }));

    const newFindings = results.filter(r => !acceptedIds.has(r.fingerprint));
    const knownFindings = results.filter(r => acceptedIds.has(r.fingerprint));

    fs.writeFileSync('${AUDIT_DIR}/semgrep-findings.json', JSON.stringify(results, null, 2));
    fs.writeFileSync('${AUDIT_DIR}/semgrep-new.json', JSON.stringify(newFindings, null, 2));

    console.log('Semgrep: ' + results.length + ' total, ' + newFindings.length + ' new, ' + knownFindings.length + ' accepted');
    newFindings.forEach(f => {
      console.log('  NEW [' + f.severity + '] ' + f.path + ':' + f.line + ' — ' + f.message.slice(0, 80));
    });
    knownFindings.forEach(f => {
      console.log('  OK  [' + f.severity + '] ' + f.path + ':' + f.line + ' — accepted');
    });

    // Exit with count of new critical/high findings
    const critical = newFindings.filter(f => f.severity === 'ERROR' || f.severity === 'WARNING');
    process.exit(critical.length > 0 ? 1 : 0);
  " && ok "semgrep: pass (no new critical findings)" || {
    NEW_FINDINGS=1
    err "semgrep: NEW findings need review"
  }
else
  err "semgrep not installed — skipping"
fi

if [ "$SEMGREP_ONLY" = true ]; then
  log "Semgrep-only mode — skipping AI auditors"
  if [ "$NEW_FINDINGS" -gt 0 ]; then
    err "SECURITY AUDIT: $NEW_FINDINGS new finding(s) need review"
    err "Results: $AUDIT_DIR/"
    exit 1
  fi
  ok "SECURITY AUDIT PASSED"
  ok "Results: $AUDIT_DIR/"
  exit 0
fi

# ── Gate 2: Build audit context ──────────────────────────────────────────────

log "Building audit context..."
CONTEXT_FILE="${AUDIT_DIR}/audit-context.md"
{
  echo "# MobiSSH — Security Audit Context"
  echo ""
  echo "## Project Overview and Architecture"
  cat CLAUDE.md
  echo -e "\n---\n"
  echo "## Security Policy"
  cat .claude/rules/security.md
  echo -e "\n---\n"
  echo "## Server Deployment (Docker + Tailscale)"
  cat .claude/rules/server.md
  echo -e "\n---\n"
  echo "## Code Style (explains escHtml usage, CSS-over-inline policy)"
  cat .claude/rules/code-style.md
  echo -e "\n---\n"
  echo "## By-Design Decisions (do NOT flag these)"
  echo "- ws:// WebSocket: allowed behind explicit danger-zone toggle with user acknowledgment"
  echo "- HTTP server on port 8081: Tailscale serve handles TLS termination externally"
  echo "- innerHTML usage: all user-controlled strings pass through escHtml() sanitizer"
  echo "- No CSP header: PWA served over Tailscale (private network), not public internet"
  echo "- PasswordCredential vault: Chrome/Android only by design, iOS blocked until WebAuthn"
} > "$CONTEXT_FILE"

AUDIT_PROMPT="You are a security auditor. The project documentation above describes MobiSSH — a mobile SSH PWA that proxies SSH connections over WebSocket via Tailscale. It uses AES-GCM encrypted vault for credentials (Chrome/Android only).

Key architecture:
- Single Node.js server: HTTP static files + WebSocket SSH bridge on port 8081
- PWA frontend with xterm.js terminal, SFTP file browser, chunked upload/download
- Tailscale (WireGuard mesh) for network-layer auth — no public internet exposure
- Service worker for offline caching (network-first, no-store headers)

Audit for security issues ranked by severity (critical/high/medium/low):
1. Credential handling: plaintext storage, vault bypass, key material in localStorage/logs
2. WebSocket bridge: command injection, SSRF via SSH host/port, auth bypass
3. XSS: user-controlled content rendered as HTML (file names, error messages)
4. SFTP: path traversal in upload/download handlers
5. Service worker: cache poisoning, stale credential exposure

For each finding: severity, file:line, description, recommended fix.
Skip theoretical issues that don't apply given the Tailscale-only deployment.
Output as markdown."

# ── Gate 3: Gemini audit ─────────────────────────────────────────────────────

log "Running Gemini security audit..."
if ! command -v gemini &>/dev/null; then
  log "gemini: not installed — skipping"
else
  GEMINI_PROMPT="IMPORTANT: First read the file ${CONTEXT_FILE} — it contains the project architecture, security policy, and deployment model. All findings must be evaluated against this context. Do NOT report issues that the documentation explicitly addresses as by-design (e.g., ws:// behind a danger-zone toggle, HTTP server behind Tailscale TLS, innerHTML with escHtml sanitization). ${AUDIT_PROMPT}"
  timeout 300 gemini -p "$GEMINI_PROMPT" > "${AUDIT_DIR}/gemini-audit.md" 2>&1 || {
    err "Gemini audit failed or timed out (5min limit)"
  }
  # Check if output is an auth error vs real audit
  if grep -qi "please set an auth\|API_KEY\|authentication" "${AUDIT_DIR}/gemini-audit.md" 2>/dev/null; then
    log "gemini: auth not configured — run 'gemini auth' to log in"
  elif [ -s "${AUDIT_DIR}/gemini-audit.md" ]; then
    ok "gemini: audit complete ($(wc -l < "${AUDIT_DIR}/gemini-audit.md") lines)"
  fi
fi

# ── Gate 4: Codex audit ──────────────────────────────────────────────────────

log "Running Codex security audit..."
if ! command -v codex &>/dev/null; then
  log "codex: not installed — skipping"
else
  CODEX_PROMPT="IMPORTANT: First read the file ${CONTEXT_FILE} — it contains the project architecture, security policy, and deployment model. All findings must be evaluated against this context. Do NOT report issues that the documentation explicitly addresses as by-design (e.g., ws:// behind a danger-zone toggle, HTTP server behind Tailscale TLS, innerHTML with escHtml sanitization). ${AUDIT_PROMPT}"
  timeout 300 codex exec "$CODEX_PROMPT" > "${AUDIT_DIR}/codex-audit.md" 2>&1 || {
    err "Codex audit failed or timed out (5min limit)"
  }
  # Check if output is an auth error vs real audit
  if grep -qi "401\|Unauthorized\|authentication\|login" "${AUDIT_DIR}/codex-audit.md" 2>/dev/null; then
    log "codex: auth not configured — run 'codex login' to authenticate"
  elif [ -s "${AUDIT_DIR}/codex-audit.md" ]; then
    ok "codex: audit complete ($(wc -l < "${AUDIT_DIR}/codex-audit.md") lines)"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

log "Audit results: $AUDIT_DIR/"
ls -la "$AUDIT_DIR/"

if [ "$NEW_FINDINGS" -gt 0 ]; then
  err "SECURITY AUDIT: new finding(s) need review in ${AUDIT_DIR}/"
  exit 1
fi

ok "SECURITY AUDIT PASSED — no new critical/high findings"
ok "Review AI audit reports in ${AUDIT_DIR}/ for informational findings"
