# Back-End Adversary Testing Plan

## Purpose
This document defines a comprehensive, adversary-driven testing strategy for the MobiSSH back-end (HTTP static server + WebSocket SSH bridge). It focuses on validating real attacker paths: unauthorized access, internal pivoting, data exposure, and service disruption.

## Scope
In scope:
- `server/index.js` HTTP serving and WebSocket upgrade/authentication.
- WebSocket message protocol (`connect`, `input`, `resize`, `disconnect`, `hostkey_response`).
- SSH bridge controls (host verification flow, auth handling, lifecycle cleanup).
- SSRF and egress controls.
- Rate limiting and anti-DoS behavior.
- Security logging and detection quality.

Out of scope:
- `node_modules` internals.
- Frontend-only UX behavior unless it impacts back-end trust boundaries.

## Threat Model (Adversary View)
Primary attacker goals:
1. Reach the WebSocket bridge without valid authorization.
2. Reuse or forge session/auth artifacts.
3. Abuse bridge functionality to access private/internal network resources.
4. Degrade service availability through connection/message floods.
5. Bypass host-key trust controls to enable MITM-style outcomes.

Assumed attacker capabilities:
- Remote network reachability to the service endpoint.
- Ability to craft raw HTTP/WebSocket requests.
- Ability to automate high-rate traffic and malformed protocol messages.
- No initial server shell access.

## Standards and Best-Practice Basis
This plan follows industry guidance from:
- OWASP Web Security Testing Guide (WSTG)
- OWASP WebSocket Security Cheat Sheet
- OWASP SSRF Prevention Cheat Sheet
- OWASP API Security Top 10 (2023)
- OWASP Logging Cheat Sheet
- OWASP Denial of Service Cheat Sheet
- OWASP ASVS
- NIST SP 800-115
- MITRE ATT&CK (initial access and service abuse techniques)
- RFC 6455 (WebSocket)

## Test Principles
- Test as an adversary, report as an engineer.
- Prefer exploit chains over isolated low-impact findings.
- Validate both prevention and detection.
- Convert high-value attack paths into repeatable CI regressions.
- Keep destructive testing controlled and time-boxed.

## Test Phases

### Phase 1: Recon and Surface Mapping
- Enumerate all HTTP routes and WS upgrade paths.
- Document headers, CSP, cache policy, and token propagation paths.
- Map trust boundaries: browser -> WS -> SSH target.
- Identify data/control paths that cross privilege boundaries.

Deliverable:
- Attack-surface map with entry points and trust assumptions.

### Phase 2: Threat-Driven Test Design
- Build abuse cases per boundary:
  - Handshake/auth bypass
  - Token theft/replay
  - SSRF/internal pivot
  - Protocol parser abuse
  - Connection/resource exhaustion
- Prioritize by likelihood x impact x detection gap.

Deliverable:
- Prioritized test matrix with severity hypotheses.

### Phase 3: Control Validation
Execute deterministic tests against expected controls.

#### A. HTTP/WS Handshake Security
- Missing/invalid/expired token should fail upgrade.
- Replay token attempts should be rejected or constrained.
- Upgrade path should resist malformed URL/query parsing.
- Validate origin/trust handling for cross-site attempts.

#### B. WS Protocol Hardening
- Message fuzzing by type, field, and size.
- Type confusion: non-string `data`, oversized numeric fields, null/arrays.
- Fragmentation/compression boundary tests.
- Unknown message types should fail safely without state corruption.

#### C. SSRF/Egress Protection
- Attempt private targets using:
  - Hostnames resolving to private ranges
  - IPv4-mapped IPv6 and alternate IP notations
  - Redirect-based pivots
  - DNS rebinding scenarios
- Validate that policy holds at app and network layers.

#### D. Rate Limiting and DoS
- Upgrade floods from single and rotating identities.
- Abuse of forwarded-client-IP headers.
- Message-rate floods and oversized payload pressure.
- Reconnect-storm and stale-session churn behavior.
- Validate memory/CPU behavior under sustained load.

#### E. SSH Trust/Host-Key Flow
- First-connect host-key acceptance path.
- Mismatch warnings and reject/accept transitions.
- Attempt race conditions around pending verification.
- Confirm no auth or shell access prior to explicit verification outcome.

#### F. Static Serving and Security Headers
- Path traversal and normalization bypass attempts.
- CSP policy validation with active bypass probes.
- Cache semantics for dynamic/auth-bearing responses.

Deliverable:
- Control validation report (pass/fail + reproducible evidence).

### Phase 4: Exploitation and Chaining
- Combine weaker findings to simulate real-world compromise paths.
- Demonstrate impact with minimal blast radius:
  - Unauthorized bridge usage
  - Internal service reachability
  - Resource exhaustion with realistic bot behavior

Deliverable:
- Attack chain narratives with proof and business impact.

### Phase 5: Detection and Response Assessment
- Confirm logs capture:
  - Auth/token failures
  - SSRF block events
  - Rate-limit triggers
  - Host-key mismatch/rejection
- Verify alerting thresholds and runbook usability.
- Measure time-to-detect and time-to-contain in tabletop drills.

Deliverable:
- Detection coverage matrix and response readiness score.

### Phase 6: Retest and Regressionization
- Retest all fixed issues.
- Promote critical paths into automated security tests.
- Block releases on high-severity regressions.

Deliverable:
- Signed retest report and CI security gate checklist.

## Concrete Test Matrix

### Identity and Session Controls
- WS upgrade without token.
- WS upgrade with malformed token format.
- WS upgrade with expired token.
- WS upgrade with replayed token from prior page load.
- Token observed in logs/referrer/history checks.

### Input and Parser Abuse
- JSON parse bombs (deep nesting / large arrays).
- Invalid UTF-8 and binary frame behavior.
- Payloads at and above max configured boundaries.
- Numeric overflows/negative values for `resize`.

### Network Pivot / SSRF
- Private IP direct attempt (expected blocked by default).
- Hostname resolving to private IP attempt.
- IPv6 loopback/link-local/ULA attempts.
- Obfuscated address formats and mixed notation.
- Rebinding host between validation and connect.

### Availability / Resource Exhaustion
- Concurrent connection cap verification.
- Rapid connect/disconnect churn tests.
- Reconnect amplification behavior after forced disconnect.
- Ping/pong timeout enforcement under dropped responses.

### Trust Workflow Integrity
- Host-key prompt spoof resistance.
- Reject path results in hard stop (no shell channel).
- Accept path stores/update semantics for known hosts.
- Mismatch acceptance requires explicit user action.

### Security Observability
- Event-level logging completeness.
- No sensitive secrets in logs.
- Correlation fields present (client IP, session id, reason).

## Tooling
Recommended stack:
- Dynamic scanning: OWASP ZAP, Burp Suite.
- WS scripting/fuzzing: `wscat`, custom Node harnesses.
- Load abuse: k6/Artillery + custom WS flood scripts.
- Traffic analysis: tcpdump/Wireshark.
- SAST/SCA: Semgrep + dependency audit.

## CI/CD Integration Plan

### Required on every PR
- Fast negative tests for WS auth handshake.
- Protocol schema/robustness tests for message handling.
- SSRF regression suite (known bypass payload set).
- Rate-limit sanity checks.

### Nightly/weekly
- Extended fuzzing and long-run DoS simulations.
- Attack-chain replay scenarios.
- Detection-and-alert validation tests.

### Release gate
- No open high/critical findings.
- All prior high/critical findings have regression tests.
- Detection coverage for auth, SSRF, and DoS events is verified.

## Reporting Template
Each finding must include:
- Title and severity.
- Affected component and trust boundary.
- Reproduction steps (scriptable).
- Observed behavior and impact.
- Detection quality (logged? alerted?).
- Mitigation recommendation.
- Retest status.

## Severity Guidance
- Critical: remote unauthorized bridge control, broad internal pivot, or complete outage path.
- High: reliable SSRF/internal reach, auth bypass under realistic conditions, severe DoS.
- Medium: meaningful control bypass with constraints.
- Low: hardening gaps and non-exploitable hygiene issues.

## 30/60/90-Day Execution Roadmap

### 0-30 days
- Build attack-surface map.
- Implement handshake negative tests.
- Implement SSRF bypass test corpus.
- Add basic rate-limit abuse checks.

### 31-60 days
- Add protocol fuzz harness.
- Add reconnect-storm/DoS soak tests.
- Integrate detection verification checks.

### 61-90 days
- Run full adversary exercise with chained attack scenarios.
- Finalize release gating policy.
- Baseline metrics (finding density, MTTR, detection latency).

## Success Criteria
- No unauthorized WS upgrade paths.
- No SSRF pivot to private/internal destinations under default policy.
- Rate limits and concurrency controls resist automation abuse.
- Host-key trust flow cannot be bypassed before explicit decision.
- High-risk attack events are logged and alertable.
