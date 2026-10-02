// Centralized compile-time gate for RAW terminal-derived diagnostics (#1109-A).
//
// Raw terminal OUTPUT (the byte-trace), remote OSC/hook message text, and
// verbatim selection text are DEVELOPMENT-TIME diagnostics only: they can carry
// secrets a runtime scrubber cannot reliably catch (a token echoed on screen, a
// password in scrollback). Per the owner decision (#1109), that content is
// COMPILED OUT of public release builds rather than scrubbed at runtime.
//
// This single const is the gate. Raw terminal-derived content is captured and
// uploaded ONLY when it is true. Public release builds pass nothing, so it
// resolves to its `defaultValue: false`; every `if (kRawContentDiagnosticsEnabled)`
// block then becomes dead code the AOT (`--release`) compiler tree-shakes out —
// verified by codex to survive `--split-per-abi` / `--obfuscate` /
// `--split-debug-info`, and to FAIL CLOSED (an unset define → false → no raw
// content). A tracing-enabled internal build passes
// `--dart-define=MOBISSH_RAW_DIAGNOSTICS=true`.
//
// Mirrors the `String.fromEnvironment` idiom of [feedbackEndpoint] /
// [feedbackKey] below.
const bool kRawContentDiagnosticsEnabled = bool.fromEnvironment(
  'MOBISSH_RAW_DIAGNOSTICS',
  defaultValue: false,
);

/// Endpoint that ingests bug reports. Compile-time overridable (#966): the
/// personal build keeps the tailnet default; the PUBLIC Play build points at the
/// Cloudflare Worker via `--dart-define=MOBISSH_FEEDBACK_ENDPOINT=…`
/// (see infra/bug-report-worker/). The orchestrator's watcher polls the files
/// the tailnet endpoint writes. Crash uploads (#1243) go to the same origin.
const String feedbackEndpoint = String.fromEnvironment(
  'MOBISSH_FEEDBACK_ENDPOINT',
  defaultValue: 'https://mobissh.tailbe5094.ts.net/api/bug-report',
);

/// Shared key sent as `X-MobiSSH-Key` by every uploader (bug report, crash).
/// The relay's feedback guard (#484/#1115) rejects uploads without it. Baked
/// in by `--dart-define=MOBISSH_FEEDBACK_KEY=…` (ship-native / release AAB);
/// empty → no header. Never logged.
const String feedbackKey = String.fromEnvironment('MOBISSH_FEEDBACK_KEY');
