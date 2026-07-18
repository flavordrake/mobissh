// Per-session "reset terminal input modes" signal — the MANUAL counterpart to
// the #1014 auto-reset that fires on reconnect.
//
// The stuck-mouse-mode trap: a TUI (or a dropped-mid-TUI reconnect) leaves the
// terminal in mouse-reporting mode at a bare prompt. Every tap then synthesises
// an SGR mouse report that the shell echoes as literal `0;19;13M` garbage — and
// because that garbage lands on the command line, the user can't even TYPE their
// way out, and reconnect can't recover it (a still-alive TUI re-enables the
// modes right after the #1014 reset). See ghostty_terminal_view's shellReady
// handler.
//
// The keybar's Reset key bumps this session's counter; GhosttyTerminalView
// `ref.listen`s and runs the LOCAL DECRST input-mode reset (no bytes to the
// remote, no reconnect) so taps stop synthesising immediately. A counter (not a
// bool) so a second tap fires again even if the first left modes clear.
//
// A NEW file in state/, deliberately separate from the #589-sensitive
// session/connection providers (mirrors ctrl_modifier_provider.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Monotonic per-session reset counter (sessionId → tick). Each [requestReset]
/// bumps one session's tick; the terminal view compares against the previous
/// value and resets input modes when it changes.
class InputModeResetNotifier extends StateNotifier<Map<String, int>> {
  InputModeResetNotifier() : super(const {});

  /// Request a one-shot input-mode reset for [sessionId] (the keybar Reset key).
  void requestReset(String sessionId) {
    state = {...state, sessionId: (state[sessionId] ?? 0) + 1};
  }
}

/// Per-session reset signal. Driven by the keybar Reset key; watched by
/// GhosttyTerminalView.
final inputModeResetProvider =
    StateNotifierProvider<InputModeResetNotifier, Map<String, int>>(
  (ref) => InputModeResetNotifier(),
);
