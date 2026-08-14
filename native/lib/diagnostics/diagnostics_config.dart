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
// Mirrors the existing `String.fromEnvironment` idiom in
// `ui/feedback_overlay.dart` (`MOBISSH_FEEDBACK_ENDPOINT` / `MOBISSH_FEEDBACK_KEY`).
const bool kRawContentDiagnosticsEnabled = bool.fromEnvironment(
  'MOBISSH_RAW_DIAGNOSTICS',
  defaultValue: false,
);
