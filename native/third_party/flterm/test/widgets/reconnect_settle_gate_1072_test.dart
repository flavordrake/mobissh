@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1072: the RECONNECT-SETTLE auto-reply gate.
///
/// On a reconnect/revive the remote (tmux) is mid-reattach and does not consume
/// terminal AUTO-replies (DA/DSR/CPR answers, focus + mouse reports), so its tty
/// echoes them as literal input at the idle prompt — the owner's recurring
/// `?62c` (DA reply) leak. [TerminalController.beginReconnectSettle] opens a
/// short window during which those auto-replies are DROPPED instead of written
/// to the PTY. User keystrokes/text/paste are never gated. The window is
/// time-bounded so first-connect capability detection and a relaunched TUI's
/// live queries (after the window) are answered normally.
///
/// The DA request (`CSI c`) is the canonical trigger: libghostty answers it via
/// `onWritePty` (the same channel all its auto-replies use), so gating that
/// channel is what stops `?62c`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reconnect-settle auto-reply gate (#1072)', () {
    late TerminalControllerImpl controller;

    setUp(() => controller = TerminalControllerImpl());
    tearDown(() => controller.dispose());

    void writeUtf8(String text) =>
        controller.write(Uint8List.fromList(utf8.encode(text)));

    test('DA auto-reply flows to the PTY when no settle is armed', () {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      writeUtf8('\x1b[c');

      expect(output.map(utf8.decode).join(), contains('\x1b[?62c'),
          reason: 'baseline: an un-gated DA request is answered to the PTY');
    });

    test('DA auto-reply is DROPPED during the reconnect-settle window', () {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      controller.beginReconnectSettle();
      writeUtf8('\x1b[c');

      expect(output, isEmpty,
          reason: 'the DA reply must NOT reach the PTY during settle — this is '
              'the `?62c` leak the gate stops');
    });

    test('the diagnostics tee STILL observes the reply while it is gated', () {
      final replies = <Uint8List>[];
      final output = <Uint8List>[];
      controller.onTerminalReply = replies.add;
      controller.onOutput = output.add;

      controller.beginReconnectSettle();
      writeUtf8('\x1b[c');

      // The tee fires (so the bug-report ring still records the reply) but the
      // forward to the PTY is dropped.
      expect(replies, isNotEmpty,
          reason: 'onTerminalReply must still observe for diagnostics');
      expect(output, isEmpty, reason: 'but the reply must not reach the PTY');
    });

    test('DA auto-reply flows again after the settle window elapses', () async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      controller.beginReconnectSettle();
      // Wait past the 600ms window (real timer — this is a plain `test`).
      await Future<void>.delayed(const Duration(milliseconds: 750));
      writeUtf8('\x1b[c');

      expect(output.map(utf8.decode).join(), contains('\x1b[?62c'),
          reason: 'the gate is time-bounded: a live query after the window '
              'is answered normally');
    });

    test('re-arming resets the window', () async {
      final output = <Uint8List>[];
      controller.onOutput = output.add;

      controller.beginReconnectSettle();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      controller.beginReconnectSettle(); // re-arm before the first elapsed
      await Future<void>.delayed(const Duration(milliseconds: 400));
      // 800ms total, but only 400ms since the re-arm → still active.
      writeUtf8('\x1b[c');

      expect(output, isEmpty,
          reason: 're-arming must reset the timer, not stack windows');
    });
  });
}
