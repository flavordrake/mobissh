// Tests for applying the armed keybar Ctrl modifier to SOFT-KEYBOARD input on
// the Ghostty backend (#728).
//
// The keybar Ctrl modifier (#694) only transformed KEYBAR key presses. There are
// no letter keys on the keybar, so to send Ctrl+R the user types R on the soft
// keyboard — which flows through flterm's `controller.onOutput(bytes) →
// proxy.sendInput` and never reached the keybar's `CtrlModifier`. #728 reads the
// shared armed flag in that input path and transforms the next typed character.
//
// `ghosttyApplyArmedCtrl(armed, bytes)` is the PURE decision: given the armed
// flag and the typed bytes, it returns the bytes to actually send plus whether
// the one-shot Ctrl should now be cleared. It mirrors the keybar's `ctrlTransform`
// so keybar-key and keyboard-key Ctrl behave identically.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyApplyArmedCtrl — armed + single letter (#728)', () {
    test("armed + 'R' (0x52) → 0x12 (Ctrl+R), cleared", () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: 'R');
      expect(r.bytes, equals('\x12'));
      expect(r.bytes.codeUnitAt(0), equals(0x12));
      expect(r.shouldClear, isTrue);
    });

    test("armed + 'r' (0x72) → 0x12 (case-insensitive), cleared", () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: 'r');
      expect(r.bytes, equals('\x12'));
      expect(r.bytes.codeUnitAt(0), equals(0x12));
      expect(r.shouldClear, isTrue);
    });

    test("armed + 'c' → 0x03 (Ctrl+C), cleared", () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: 'c');
      expect(r.bytes, equals('\x03'));
      expect(r.shouldClear, isTrue);
    });

    test('every a–z maps to byte 1..26 via & 0x1f when armed', () {
      for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++) {
        final letter = String.fromCharCode(c);
        final r = ghosttyApplyArmedCtrl(armed: true, bytes: letter);
        expect(
          r.bytes.codeUnitAt(0),
          equals(c & 0x1f),
          reason: 'armed Ctrl+$letter should be byte ${c & 0x1f}',
        );
        expect(r.shouldClear, isTrue);
      }
    });
  });

  group('ghosttyApplyArmedCtrl — armed + non-letter single char (#728)', () {
    test("armed + '5' → passthrough '5', still cleared (one-shot)", () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: '5');
      expect(
        r.bytes,
        equals('5'),
        reason: 'a digit has no letter control meaning → unmodified',
      );
      expect(
        r.shouldClear,
        isTrue,
        reason: 'Ctrl auto-clears after one key even on a non-letter',
      );
    });

    test("armed + '/' → passthrough '/', cleared", () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: '/');
      expect(r.bytes, equals('/'));
      expect(r.shouldClear, isTrue);
    });

    test("armed + a CR ('\\r') → passthrough, cleared", () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: '\r');
      expect(r.bytes, equals('\r'));
      expect(r.shouldClear, isTrue);
    });
  });

  group('ghosttyApplyArmedCtrl — armed + multi-char (IME/paste) (#728)', () {
    test('armed + multi-char string → passthrough UNCHANGED, cleared', () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: 'hello world');
      expect(
        r.bytes,
        equals('hello world'),
        reason: 'never corrupt multi-byte IME/paste — pass through unchanged',
      );
      expect(
        r.shouldClear,
        isTrue,
        reason: 'the one-shot Ctrl still clears so it does not get stuck',
      );
    });

    test('armed + a CSI escape (multi-byte) → passthrough, cleared', () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: '\x1b[A');
      expect(r.bytes, equals('\x1b[A'));
      expect(r.shouldClear, isTrue);
    });

    test('armed + empty string → passthrough empty, cleared', () {
      final r = ghosttyApplyArmedCtrl(armed: true, bytes: '');
      expect(r.bytes, equals(''));
      expect(r.shouldClear, isTrue);
    });
  });

  group('ghosttyApplyArmedCtrl — NOT armed (#728)', () {
    test("not armed + 'R' → passthrough, NOT cleared", () {
      final r = ghosttyApplyArmedCtrl(armed: false, bytes: 'R');
      expect(r.bytes, equals('R'));
      expect(
        r.shouldClear,
        isFalse,
        reason: 'nothing to clear when Ctrl was not armed',
      );
    });

    test('not armed + multi-char → passthrough unchanged, NOT cleared', () {
      final r = ghosttyApplyArmedCtrl(armed: false, bytes: 'ls -la');
      expect(r.bytes, equals('ls -la'));
      expect(r.shouldClear, isFalse);
    });
  });
}
