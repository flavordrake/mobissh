// Feature flag for the tmux control-mode (`tmux -CC`) integration arc (epic #906).
//
// Part A (#907) built + validated a PURE control-mode parser only; it changed
// NOTHING in the live scrape/render/gesture path. Part B (#909, this change)
// wires the parser into a RENDER path (%output → grid, `refresh-client -C` as
// the single resize primitive) behind this flag. Part C (gestures via control
// mode) is still to come. Until the feature is device-validated the flag stays
// OFF so the proven screen-scrape path remains the default.
//
// WHY a mutable top-level (not a compile-time const): Part B's emulator parity
// test (`integration_test/cc_render_test.dart`) and the host-level unit tests
// must run the control-mode path with the flag ON, then restore OFF. A `const`
// can't be flipped at runtime, and threading a flag parameter through every
// session/host/proxy seam would scatter the gate across unrelated code. A single
// mutable global, flipped only via [setTmuxControlModeForTest] (or — later — a
// real settings toggle), keeps the gate in ONE place. It still DEFAULTS false,
// so the shipped release path is unchanged. Reads are cheap; there is exactly
// one writer.
bool tmuxControlMode = false;

/// Flip [tmuxControlMode] for a test, returning the PREVIOUS value so the caller
/// can restore it in a tearDown (tests must never leak the ON state to the rest
/// of the suite — the flag-off path is the shipped default and every other test
/// asserts against it). Test-only.
bool setTmuxControlModeForTest(bool value) {
  final prev = tmuxControlMode;
  tmuxControlMode = value;
  return prev;
}
