// Tests for the per-session signal detector (#575).
//
// The detector scans a session's PTY output stream for "attention" signals:
//   - OSC 9  (ESC ] 9 ; <message> BEL|ST) — the iTerm/desktop-notification
//     convention the PWA already uses (notify-bell.sh emits OSC 9).
//   - the terminal BEL (\a) as a fallback attention signal (no message).
//
// It is keyed by sessionId and emits a [SessionSignalKind.ready] with the
// parsed message. Chunk boundaries can split an escape sequence, so the
// detector must buffer across feeds. This is the producer half of the
// notification path; posting the OS notification + the tap are device-only.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_notification.dart';
import 'package:mobissh/services/session_signal_detector.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  test('OSC 9 with BEL terminator → ready signal carrying the message', () {
    final signals = <SessionSignal>[];
    final d = SessionSignalDetector(onSignal: signals.add);
    // ESC ] 9 ; build finished BEL
    d.feed(_b('\x1b]9;build finished\x07'));
    expect(signals, hasLength(1));
    expect(signals.first.kind, SessionSignalKind.ready);
    expect(signals.first.message, 'build finished');
  });

  test('OSC 9 with ST (ESC backslash) terminator is also recognized', () {
    final signals = <SessionSignal>[];
    final d = SessionSignalDetector(onSignal: signals.add);
    d.feed(_b('\x1b]9;ready\x1b\\'));
    expect(signals, hasLength(1));
    expect(signals.first.message, 'ready');
  });

  test('bare BEL → ready signal with no message (fallback attention)', () {
    final signals = <SessionSignal>[];
    final d = SessionSignalDetector(onSignal: signals.add);
    d.feed(_b('done\x07'));
    expect(signals, hasLength(1));
    expect(signals.first.kind, SessionSignalKind.ready);
    expect(signals.first.message, isNull);
  });

  test('escape sequence split across two feeds is still detected', () {
    final signals = <SessionSignal>[];
    final d = SessionSignalDetector(onSignal: signals.add);
    d.feed(_b('\x1b]9;hello'));
    expect(signals, isEmpty, reason: 'incomplete sequence — wait for more');
    d.feed(_b(' world\x07'));
    expect(signals, hasLength(1));
    expect(signals.first.message, 'hello world');
  });

  test('plain output with no signal emits nothing', () {
    final signals = <SessionSignal>[];
    final d = SessionSignalDetector(onSignal: signals.add);
    d.feed(_b('just some normal terminal output\nline 2\n'));
    expect(signals, isEmpty);
  });

  test(
    'OSC 9 takes precedence over a BEL inside the same chunk (no double)',
    () {
      final signals = <SessionSignal>[];
      final d = SessionSignalDetector(onSignal: signals.add);
      // The BEL here is the OSC terminator, not a standalone bell.
      d.feed(_b('\x1b]9;all set\x07'));
      expect(signals, hasLength(1));
      expect(signals.first.message, 'all set');
    },
  );
}
