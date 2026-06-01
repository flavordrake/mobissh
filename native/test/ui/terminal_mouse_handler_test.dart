// Unit tests for WheelFixMouseHandler (#617).
//
// Pins the corrected mouse-wheel SGR encoding: xterm-4.0.0 emits button 68/69
// for wheel-up/down (which tmux ignores); the handler must emit the canonical
// 64/65 so tmux/less scrollback works. Non-wheel + non-scroll events must defer
// to the library's defaultMouseHandler unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';
import 'package:mobissh/ui/terminal_mouse_handler.dart';

/// Minimal [TerminalState] stand-in so we can exercise the handler without a
/// full Terminal. Only the fields the handler reads are populated.
class _FakeState implements TerminalState {
  _FakeState(this.mouseMode, this.mouseReportMode);

  @override
  final MouseMode mouseMode;

  @override
  final MouseReportMode mouseReportMode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TerminalMouseEvent _event(
  TerminalMouseButton button,
  TerminalMouseButtonState state, {
  MouseMode mode = MouseMode.upDownScrollDrag,
  MouseReportMode reportMode = MouseReportMode.sgr,
  int x = 26,
  int y = 26,
}) {
  return TerminalMouseEvent(
    button: button,
    buttonState: state,
    position: CellOffset(x, y),
    state: _FakeState(mode, reportMode),
    platform: TerminalTargetPlatform.linux,
  );
}

void main() {
  const handler = WheelFixMouseHandler();

  group('SGR wheel reports (the tmux fix)', () {
    test('wheel-up down → canonical button 64, not the buggy 68', () {
      final out = handler(
        _event(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down),
      );
      // CellOffset is 0-based; report is 1-based → 27;27.
      expect(out, '\x1b[<64;27;27M');
      expect(out, isNot(contains('68')));
    });

    test('wheel-down down → canonical button 65, not the buggy 69', () {
      final out = handler(
        _event(TerminalMouseButton.wheelDown, TerminalMouseButtonState.down),
      );
      expect(out, '\x1b[<65;27;27M');
      expect(out, isNot(contains('69')));
    });

    test('wheel "up" (release) is never reported', () {
      final out = handler(
        _event(TerminalMouseButton.wheelUp, TerminalMouseButtonState.up),
      );
      expect(out, isNull);
    });
  });

  group('deferral to the library handler', () {
    test('non-wheel button in a scroll mode falls through to default', () {
      // In upDownScrollDrag the default handler reports drags for left button;
      // we only assert the handler does NOT hijack it as a wheel report.
      final out = handler(
        _event(TerminalMouseButton.left, TerminalMouseButtonState.down),
      );
      // Whatever the default returns, it must not be a wheel (64/65) report.
      if (out != null) {
        expect(out, isNot(contains('<64;')));
        expect(out, isNot(contains('<65;')));
      }
    });

    test('wheel button when mouseMode reports no scroll → no wheel report', () {
      // mode.none does not report scroll; defer (default returns null).
      final out = handler(
        _event(
          TerminalMouseButton.wheelUp,
          TerminalMouseButtonState.down,
          mode: MouseMode.none,
        ),
      );
      expect(out, isNull);
    });
  });

  group('other report encodings', () {
    test('normal/X10 wheel-up uses 32 + 64 button byte', () {
      final out = handler(
        _event(
          TerminalMouseButton.wheelUp,
          TerminalMouseButtonState.down,
          reportMode: MouseReportMode.normal,
          x: 0,
          y: 0,
        ),
      );
      // btn = 32 + 64 = 96 ('`'); col/row = 32 + 1 = 33 ('!').
      expect(out, '\x1b[M${String.fromCharCode(96)}!!');
    });
  });
}
