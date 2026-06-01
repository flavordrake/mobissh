// Correct mouse-wheel SGR reporter for touch scrollback in tmux/less/etc (#617).
//
// ROOT CAUSE (device-confirmed on emulator with a real tmux, mouse on):
// xterm-4.0.0 emits the WRONG button code for mouse-wheel reports. The SGR
// mouse protocol (DECSET ?1006) encodes wheel-up as button **64** and
// wheel-down as **65** (the 0x40 "wheel" bit OR'd with button 0/1). But
// xterm-4.0.0 defines `TerminalMouseButton.wheelUp(id: 64 + 4) = 68` /
// `wheelDown(id: 64 + 5) = 69` and feeds that id straight into the SGR report
// (`reporter.dart`: `final buttonID = button.id;`). The result on a touch drag
// in tmux's alternate buffer was:
//
//     ESC[<68;27;27M   (repeated)
//
// tmux does not recognise button 68/69 as wheel events, so it dropped them and
// scrollback never moved — even though mouseMode was correctly
// `upDownScrollDrag` and the gesture path was emitting bytes. (Diagnostic in
// integration_test/tmux_scrollback_test.dart logged exactly this.)
//
// The correct sequence is `ESC[<64;x;yM` (wheel-up) / `ESC[<65;x;yM`
// (wheel-down), which tmux/less/vim all understand.
//
// FIX STRATEGY: the bug is in pub-cache (ephemeral, not editable), and the
// `Terminal` exposes a public `mouseHandler` field. So we install an app-level
// handler that emits the canonical wheel report for wheel buttons in a scroll
// report mode, and delegates everything else (clicks, drags, non-wheel) to the
// library's `defaultMouseHandler`. Wired in `sessions.dart` when each session's
// `Terminal` is created.

import 'package:xterm/core.dart';

/// Canonical SGR/normal/urxvt mouse-wheel button codes. The wheel bit is 0x40
/// (64); wheel-up adds button 0, wheel-down button 1. xterm-4.0.0 instead uses
/// 68/69, which terminals treat as unknown buttons.
const int _kWheelUpCode = 64; // 0x40 | 0
const int _kWheelDownCode = 65; // 0x40 | 1
const int _kWheelLeftCode = 66; // 0x40 | 2
const int _kWheelRightCode = 67; // 0x40 | 3

/// A [TerminalMouseHandler] that corrects xterm-4.0.0's wheel-button SGR
/// encoding (#617) and otherwise defers to [defaultMouseHandler].
///
/// Only wheel buttons in a scroll-reporting mode are rewritten; clicks, drags,
/// and non-wheel events fall through to the library handler unchanged, so this
/// is a minimal, surgical override.
class WheelFixMouseHandler implements TerminalMouseHandler {
  const WheelFixMouseHandler();

  /// Map a (buggy) library wheel button id to its canonical wheel code, or null
  /// if the button is not a wheel button.
  int? _canonicalWheelCode(TerminalMouseButton button) {
    if (!button.isWheel) return null;
    switch (button) {
      case TerminalMouseButton.wheelUp:
        return _kWheelUpCode;
      case TerminalMouseButton.wheelDown:
        return _kWheelDownCode;
      case TerminalMouseButton.wheelLeft:
        return _kWheelLeftCode;
      case TerminalMouseButton.wheelRight:
        return _kWheelRightCode;
      default:
        return null;
    }
  }

  @override
  String? call(TerminalMouseEvent event) {
    final mode = event.state.mouseMode;
    // Only scroll-reporting modes report wheel events at all.
    if (!mode.reportScroll) {
      return defaultMouseHandler(event);
    }

    final wheelCode = _canonicalWheelCode(event.button);
    if (wheelCode == null) {
      // Not a wheel button — let the library handle drags/clicks normally.
      return defaultMouseHandler(event);
    }

    // Wheel buttons never report an "up" (release) event.
    if (event.buttonState == TerminalMouseButtonState.up) {
      return null;
    }

    // Coordinates are 1-based (the offset is 0-based).
    final x = event.position.x + 1;
    final y = event.position.y + 1;

    switch (event.state.mouseReportMode) {
      case MouseReportMode.sgr:
        // The form tmux/vim/less expect: ESC [ < code ; x ; y M
        return '\x1b[<$wheelCode;$x;${y}M';
      case MouseReportMode.urxvt:
        // ESC [ code ; x ; y M  (code already includes the 0x40 wheel bit; the
        // 32 offset that urxvt normally adds to a button id is the +32 of the
        // 0x20 motion space — wheel codes carry 0x40 directly).
        return '\x1b[$wheelCode;$x;${y}M';
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        // X10/normal encoding: button byte = 32 + code, position bytes 32 + n.
        final btn = String.fromCharCode(32 + wheelCode);
        final col = String.fromCharCode(32 + x);
        final row = String.fromCharCode(32 + y);
        return '\x1b[M$btn$col$row';
    }
  }
}
