# Candidate 3: boot-splash — inline diagnostic → extracted pure module

## What happened
The connection overlay's 5s watchdog in `_openWebSocket` (connection.ts)
originally showed only "Connecting to <url>..." with no layer diagnostic.
In the boot-splash-telemetry arc (this session, 2026-04-09), the user
asked for layered text explaining which network layer was stuck.

The diagnostic cascade was extracted as `src/modules/connect-probe.ts` —
a pure function `(onLine, fetchImpl, ws) → ProbeLine[]` with three
deterministic checks (radio → HTTP → WebSocket). The probe module has
16 unit tests covering every failure mode, cascade ordering, and
custom-URL paths. The caller in `connection.ts` was refactored from
a single `_showConnectionStatus("Connecting...")` to a probe invocation
that appends diagnostic lines to the same overlay.

## What crystallize should find
- **Phase 1 (audit):** the before-version of connection.ts has the 5s
  timeout inline. The operations inside (checking navigator.onLine,
  fetching /version, inspecting ws.readyState) are all deterministic.
  If a skill doc described this flow, every step would be B-bucket.
- **Phase 2 (discover):** `connect-probe.ts` exists after extraction.
  16 tests exist. Phase 2 should find the module as a tool with a
  clear contract: ProbeDeps → ProbeLine[].
- **Phase 5 (verify):** the 16 tests are the fixtures. Crystallize
  should confirm the module is deterministic by running them (or
  noting their existence and pass status).

## What makes this candidate special
- This is a **code module extraction**, not a script extraction. The
  crystallize skill's phase 4 targets shell scripts, but this proves
  the same principle works for TypeScript modules with typed contracts.
- The TRACE for this arc exists at
  `.traces/trace-boot-splash-telemetry-210808/` with full decision
  chain.
- The extraction happened in the same session that wrote the
  crystallize skill — it IS a crystallization, just done by hand
  before the skill existed to do it.

## Ground truth
- Before: connection.ts line 552-557 (5s timeout, single message)
- After: connection.ts calls probeConnectLayers() from connect-probe.ts
- Extracted module: connect-probe.ts (152 lines, pure function)
- Tests: connect-probe.test.ts (246 lines, 16 tests)

## Fixture files
- connection-before.ts: connection.ts at b300f3e (pre-probe)
- connection-after.ts: connection.ts at e0991ca (post-probe)
- connect-probe.ts: the extracted module at e0991ca
- connect-probe.test.ts: the 16-test fixture suite at e0991ca
