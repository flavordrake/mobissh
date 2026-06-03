// Tests for the sticky Ctrl modifier on the keybar (#694).
//
// PWA `ctrlActive` parity: tap Ctrl to ARM, the next keybar key transforms to
// its control byte, then Ctrl AUTO-CLEARS (one-shot sticky). Tapping Ctrl while
// armed toggles it OFF (cancel). A non-letter key while armed sends unmodified
// and still clears Ctrl.
//
// The byte-transform is a PURE helper (`ctrlTransform`) so it's unit-testable
// without pumping widgets — the keybar widget tap path hangs the headless
// harness on Material ripple animations (see keybar_test.dart). The arm/clear
// lifecycle is exercised through `CtrlModifier`, a plain state holder the
// widget delegates to, so the state machine is covered without a live tap.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/keybar.dart';

void main() {
  group('ctrlTransform — letter → control byte (#694)', () {
    test('lowercase a → \\x01 (Ctrl+A)', () {
      expect(ctrlTransform('a'), equals('\x01'));
    });

    test('uppercase A → \\x01 (case-insensitive, matches PWA)', () {
      expect(ctrlTransform('A'), equals('\x01'));
    });

    test('l/L → \\x0c (Ctrl+L, clear screen)', () {
      expect(ctrlTransform('l'), equals('\x0c'));
      expect(ctrlTransform('L'), equals('\x0c'));
    });

    test('z → \\x1a (Ctrl+Z, the high end of the letter range)', () {
      expect(ctrlTransform('z'), equals('\x1a'));
    });

    test('every a–z maps to byte 1..26 via & 0x1f', () {
      for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++) {
        final letter = String.fromCharCode(c);
        final expected = c & 0x1f; // 1..26
        expect(
          ctrlTransform(letter).codeUnitAt(0),
          equals(expected),
          reason: 'Ctrl+$letter should be byte $expected',
        );
      }
    });
  });

  group('ctrlTransform — non-letter keys pass through unmodified (#694)', () {
    test('a multi-byte CSI arrow sequence is left unchanged', () {
      expect(ctrlTransform('\x1b[D'), equals('\x1b[D'));
    });

    test('a slash has no letter control meaning → unmodified', () {
      expect(ctrlTransform('/'), equals('/'));
    });

    test('an already-control byte (^C = \\x03) is unmodified', () {
      expect(ctrlTransform('\x03'), equals('\x03'));
    });

    test('an empty sequence (e.g. Paste) is unmodified', () {
      expect(ctrlTransform(''), equals(''));
    });

    test('Enter CR is left unchanged', () {
      expect(ctrlTransform('\r'), equals('\r'));
    });
  });

  group('CtrlModifier — arm / one-shot / toggle (#694)', () {
    test('starts disarmed', () {
      final m = CtrlModifier();
      expect(m.armed, isFalse);
    });

    test('arm() toggles ON from disarmed', () {
      final m = CtrlModifier();
      m.arm();
      expect(m.armed, isTrue);
    });

    test('arm() while armed toggles OFF (cancel) — Ctrl pressed twice', () {
      final m = CtrlModifier();
      m.arm();
      m.arm();
      expect(m.armed, isFalse, reason: 'second Ctrl tap cancels the modifier');
    });

    test('apply() while armed transforms a letter and auto-clears', () {
      final m = CtrlModifier();
      m.arm();
      final out = m.apply('a');
      expect(out, equals('\x01'), reason: 'armed Ctrl+a → \\x01');
      expect(m.armed, isFalse, reason: 'one-shot: Ctrl clears after one key');
    });

    test('apply() while disarmed returns the sequence verbatim', () {
      final m = CtrlModifier();
      final out = m.apply('a');
      expect(out, equals('a'));
      expect(m.armed, isFalse);
    });

    test(
      'apply() while armed on a non-letter sends unmodified, still clears',
      () {
        final m = CtrlModifier();
        m.arm();
        final out = m.apply('/');
        expect(
          out,
          equals('/'),
          reason: 'no letter control meaning → unmodified',
        );
        expect(
          m.armed,
          isFalse,
          reason: 'Ctrl still auto-clears after one key',
        );
      },
    );

    test(
      'armed → letter → armed-again requires a fresh tap (sticky one-shot)',
      () {
        final m = CtrlModifier();
        m.arm();
        expect(m.apply('a'), equals('\x01'));
        // Without re-arming, the next key is literal.
        expect(m.apply('b'), equals('b'));
        // Re-arm for the next control byte.
        m.arm();
        expect(m.apply('c'), equals('\x03'));
      },
    );
  });

  group('Ctrl key in the default layout (#694)', () {
    test('a Ctrl modifier key exists in the default keybar', () {
      final ids = kDefaultKeybarKeys.map((k) => k.id).toList();
      expect(
        ids,
        contains('keyCtrl'),
        reason: 'the sticky Ctrl modifier key must be on the default bar',
      );
    });

    test('Ctrl modifier sits immediately after Esc at the FRONT (#703)', () {
      // #703: owner device feedback moved the sticky Ctrl MODIFIER to the front
      // of the bar, immediately after Esc (overriding #694's control-group
      // placement for the modifier specifically).
      final ids = kDefaultKeybarKeys.map((k) => k.id).toList();
      final escIndex = ids.indexOf('keyEsc');
      final ctrlIndex = ids.indexOf('keyCtrl');
      expect(escIndex, equals(0), reason: 'Esc leads the bar');
      expect(
        ctrlIndex,
        equals(escIndex + 1),
        reason:
            'the Ctrl modifier must be immediately after Esc at the front of '
            'the bar (#703). Order: $ids',
      );
    });

    test('the FIXED ^C/^Z/^B/^D combos stay grouped at the END (#703)', () {
      // Only the Ctrl MODIFIER moved to the front. The fixed one-tap interrupt
      // combos keep their owner-mandated tail grouping.
      final ids = kDefaultKeybarKeys.map((k) => k.id).toList();
      final fixedCtrl = {'keyCtrlC', 'keyCtrlZ', 'keyCtrlB', 'keyCtrlD'};
      final lastNonFixedIndex = ids.lastIndexWhere(
        (id) => !fixedCtrl.contains(id),
      );
      final firstFixedIndex = ids.indexWhere((id) => fixedCtrl.contains(id));
      expect(
        firstFixedIndex,
        greaterThan(lastNonFixedIndex),
        reason:
            'fixed ^C/^Z/^B/^D combos must stay grouped at the END, not '
            'interspersed. Order: $ids',
      );
      // They are the final contiguous block.
      expect(
        ids.sublist(ids.length - 4),
        equals(['keyCtrlC', 'keyCtrlZ', 'keyCtrlB', 'keyCtrlD']),
      );
    });

    test('the Ctrl key is a modifier, not a fixed control byte', () {
      final ctrl = kDefaultKeybarKeys.firstWhere((k) => k.id == 'keyCtrl');
      // It carries no literal sequence — tapping it arms the modifier, it does
      // NOT emit a byte like ^C/^Z do.
      expect(ctrl.isModifier, isTrue);
      expect(ctrl.sequence, isEmpty);
    });

    test('the fixed ^C/^Z/^B/^D quick keys are retained (#694)', () {
      final ids = kDefaultKeybarKeys.map((k) => k.id).toSet();
      for (final id in ['keyCtrlC', 'keyCtrlZ', 'keyCtrlB', 'keyCtrlD']) {
        expect(ids, contains(id), reason: '$id must remain on the bar');
      }
    });
  });
}
