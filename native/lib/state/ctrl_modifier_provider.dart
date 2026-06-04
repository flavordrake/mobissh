// Shared sticky one-shot Ctrl-modifier state (#728).
//
// #694 gave the keybar a sticky Ctrl modifier (`CtrlModifier` in ui/keybar.dart):
// tap Ctrl to ARM, the next KEYBAR key transforms to its control byte, then Ctrl
// auto-clears (one-shot). But that armed flag lived INSIDE the keybar widget, so
// the terminal soft-keyboard input path could never read it. There are no letter
// keys on the keybar, so to send Ctrl+R the user types R on the SOFT KEYBOARD —
// which flows through flterm's `controller.onOutput(bytes) → proxy.sendInput`
// (ui/ghostty_terminal_view.dart) and never reached the keybar's `CtrlModifier`.
// Armed Ctrl + a keyboard letter did nothing and Ctrl stayed stuck armed.
//
// #728 lifts the armed flag into THIS shared Riverpod provider so BOTH the keybar
// (which drives arm/disarm as the user taps the Ctrl key) AND the terminal input
// path (which reads + one-shot-clears it before forwarding a keystroke) see the
// same state. The keybar keeps its own `CtrlModifier` for its existing #694 key
// path AND mirrors the armed state into this provider so the two stay in sync.
//
// This is a NEW file in state/ — deliberately separate from the #589-sensitive
// session/connection providers, which must not be touched.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The sticky one-shot Ctrl modifier, as a shared `bool` (true == armed).
///
/// Mirrors the keybar's `CtrlModifier` lifecycle but lives outside any widget so
/// the terminal input path can read + clear it. The terminal soft-keyboard path
/// calls [CtrlModifierNotifier.consume] to apply Ctrl to exactly the next typed
/// character (one-shot), then clears.
class CtrlModifierNotifier extends StateNotifier<bool> {
  CtrlModifierNotifier() : super(false);

  /// Arm the modifier (idempotent — arming twice stays armed; this is NOT a
  /// toggle, so the terminal path / explicit callers can force it on without
  /// accidentally cancelling). For the keybar's tap-to-cancel behaviour use
  /// [toggle].
  void arm() {
    if (!state) state = true;
  }

  /// Force the modifier off (e.g. when switching sessions, or after a keystroke
  /// consumed it through a path that doesn't call [consume]).
  void disarm() {
    if (state) state = false;
  }

  /// Flip the armed flag — mirrors the keybar's Ctrl key tap (arm if disarmed,
  /// CANCEL if already armed), matching #694's `CtrlModifier.arm`.
  void toggle() {
    state = !state;
  }

  /// One-shot read-and-clear: returns whether the modifier WAS armed, and clears
  /// it. The terminal input path calls this for each typed keystroke — when it
  /// returns true the caller applies the Ctrl transform to that one character.
  bool consume() {
    final wasArmed = state;
    if (wasArmed) state = false;
    return wasArmed;
  }
}

/// Shared armed-Ctrl flag (#728). Read by the terminal soft-keyboard input path;
/// driven by the keybar's Ctrl key.
final ctrlModifierProvider = StateNotifierProvider<CtrlModifierNotifier, bool>(
  (ref) => CtrlModifierNotifier(),
);
