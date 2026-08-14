#!/usr/bin/env bash
# scripts/security-audit-native.sh — release-gate security audit for the NATIVE
# (Flutter) app. Runs gemini + codex against the real native attack surface.
#
# The /release skill's audit prompts target the PWA (WebSocket bridge, service
# worker, WebCrypto vault). Auditing THAT surface for a native release produces
# noise and misses what matters here: flutter_secure_storage vault handling,
# dartssh2 host-key/auth paths, the SSH key LIBRARY (#1088) which now stores
# reusable private keys, SFTP path handling, port forwarding (#1047), and
# WebView-rendered remote content (image/HTML/markdown viewers).
#
# Usage: scripts/security-audit-native.sh <version>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: security-audit-native.sh <version>}"
DIR="${REPO_ROOT}/test-history/security/v${VERSION}"
CONTEXT="${DIR}/audit-context.md"
mkdir -p "$DIR"

[[ -f "$CONTEXT" ]] || "${REPO_ROOT}/scripts/build-security-context.sh" "$CONTEXT"

read -r -d '' PROMPT <<'PROMPT_EOF' || true

---

You are a security auditor reviewing the NATIVE Flutter client (native/lib) for a
release. The document above describes MobiSSH's deployment and security policy —
read it; do not guess at the attack surface.

Trust boundaries that matter:
- Tailscale mesh is the network auth boundary. "No auth on the bridge" is BY DESIGN
  and is not a finding.
- Credentials live in flutter_secure_storage (OS keychain/keystore), NOT localStorage.
  Policy: if secure storage is unavailable the feature is BLOCKED, never downgraded
  to plaintext. Flag any path that violates that.
- The app runs a two-isolate architecture: UI isolate <-> task-host isolate over a
  message gateway. Secrets crossing that boundary in cleartext messages is worth flagging.

Audit these, ranked critical/high/medium/low:
1. SSH KEY LIBRARY (native/lib/storage/keys_store.dart, secrets_store.dart): private
   key bytes must be vault-only and never land in shared_preferences, logs, or
   exported JSON. Profile export/import is a known sharp edge.
2. Credential handling generally: passphrases/passwords in logs, ctrace/telemetry
   rings, crash reports, or bug-report uploads (native/lib/diagnostics/).
3. dartssh2 usage (native/lib/ssh/): host-key verification and TOFU handling, auth
   fallback order, anything that would silently accept an unknown/changed host key.
4. SFTP path handling (native/lib/ssh/sftp_session.dart, ui/file_browser_screen.dart):
   traversal via crafted remote filenames when building LOCAL destination paths.
5. WebView-rendered REMOTE content (ui/image_file_viewer.dart, html_file_viewer.dart,
   markdown): a remote file is untrusted input. Check JS enablement, file:// access,
   and whether a hostile HTML file can reach app state or the local filesystem.
6. Port forwarding (services/port_forwarder.dart): binds must be loopback-only;
   flag anything that would expose a forward beyond 127.0.0.1.
7. Telemetry upload paths: what leaves the device, and is it scrubbed.

For each finding: severity | file:line | what an attacker does | fix.
Report ONLY findings that are real given this architecture. No theoretical noise,
no "consider adding defense in depth". Output markdown.
PROMPT_EOF

FULL="$(cat "$CONTEXT")${PROMPT}"

log() { echo "> [security-audit] $*"; }

# stderr goes to a SEPARATE .log. Folding it into the report with 2>&1 buried the
# actual answer under 1.1MB of codex model-refresh telemetry — the report has to
# stay readable or nobody reads it.
RAN_OK=0

# A tool can exit 0 having produced NOTHING useful: gemini exits on an auth error,
# codex exits after refusing because its sandbox could not read the repo. Exit
# code alone is not evidence an audit happened — look for a refusal/auth marker.
audited() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  grep -qiE 'IneligibleTierError|No permissions to create a new namespace|cannot read|blocked from auditing' "$f" && return 1
  return 0
}

if command -v gemini >/dev/null 2>&1; then
  log "running gemini (timeout 300s)"
  timeout 300 gemini -p "$FULL" > "${DIR}/gemini-audit.md" 2> "${DIR}/gemini-audit.stderr.log" || true
  if audited "${DIR}/gemini-audit.md"; then
    log "gemini: done -> ${DIR}/gemini-audit.md"
    RAN_OK=$((RAN_OK + 1))
  else
    log "gemini: NO AUDIT PRODUCED (auth/sandbox refusal — see gemini-audit.stderr.log)"
  fi
else
  log "gemini not installed"
fi

if command -v codex >/dev/null 2>&1; then
  # Pin the model EXPLICITLY so the artifact records what produced it, even though
  # it is currently also the config default — a report whose author is implicit is
  # not evidence. read-only is the least privilege that still allows an audit: it
  # must read the tree, never write it. `-a never` keeps it non-interactive.
  CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
  log "running codex (model ${CODEX_MODEL}, sandbox read-only, timeout 900s)"
  # -o writes ONLY the final message to the report. Capturing stdout instead gave
  # a 1.1MB file of streaming/model-refresh telemetry with the actual answer
  # buried at the bottom. exec is non-interactive by design — there is no
  # approval flag to pass.
  timeout 900 codex exec \
      --model "$CODEX_MODEL" \
      --sandbox read-only \
      --cd "$REPO_ROOT" \
      -o "${DIR}/codex-audit.md" \
      "$FULL" > "${DIR}/codex-audit.stdout.log" 2> "${DIR}/codex-audit.stderr.log" || true
  if audited "${DIR}/codex-audit.md"; then
    log "codex: done -> ${DIR}/codex-audit.md"
    RAN_OK=$((RAN_OK + 1))
  else
    log "codex: NO AUDIT PRODUCED (auth/sandbox refusal — see codex-audit.stderr.log)"
  fi
else
  log "codex not installed"
fi

if [[ "$RAN_OK" -eq 0 ]]; then
  log "!"
  log "! NO SECURITY AUDIT WAS PERFORMED for v${VERSION}."
  log "! This is NOT a clean audit — it is an ABSENT one. Record it as such in the"
  log "! release notes; do not let 'no findings' read as 'no problems'."
  log "!"
fi

log "audit artifacts in ${DIR}"
