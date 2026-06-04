// Tests for keybar nav-key auto-repeat on press-and-hold (#732).
//
// Press-and-hold a cursor/navigation key (arrows, Home/End, PgUp/PgDn) →
// auto-repeat the keystroke until release, with a minuscule haptic per tick.
// A quick tap = exactly ONE send (the tap path), no repeat, no double-send.
// Modifier / one-shot keys (Esc, Ctrl, Tab, symbols, ^C/^Z/^B/^D, Enter, Paste)
// do NOT repeat.
//
// Following the #694 pattern, the repeat LOGIC is a pure, widget-free holder
// (`KeyRepeatController`) so the timer lifecycle is unit-testable with
// `fakeAsync` (NO real delays) — the keybar widget tap path hangs the headless
// harness on Material ripple animations (see keybar_test.dart). Eligibility is
// an explicit Set keyed on the key id so it's trivial to extend.
//
// The haptic is device-validated (the owner) — the controller fires only the
// send `onTick`; the widget supplies a tick callback that does send + haptic.
// These tests assert the TICK COUNT (the send path), not the haptic.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/keybar.dart';

void main() {
  group('repeat-eligible key set (#732)', () {
    test('all four arrows are repeat-eligible', () {
      for (final id in ['keyLeft', 'keyUp', 'keyDown', 'keyRight']) {
        expect(
          isRepeatEligibleKeyId(id),
          isTrue,
          reason: '$id (a cursor key) must auto-repeat on hold',
        );
      }
    });

    test('Home/End and PgUp/PgDn are repeat-eligible (cursor movement)', () {
      for (final id in ['keyHome', 'keyEnd', 'keyPgUp', 'keyPgDn']) {
        expect(
          isRepeatEligibleKeyId(id),
          isTrue,
          reason: '$id is a navigation/cursor key and should repeat',
        );
      }
    });

    test('modifier / one-shot / symbol keys are NOT repeat-eligible', () {
      for (final id in [
        'keyEsc',
        'keyCtrl',
        'keyTab',
        'keySlash',
        'keyDash',
        'keyPipe',
        'keyEnter',
        'keyPaste',
        'keyCtrlC',
        'keyCtrlZ',
        'keyCtrlB',
        'keyCtrlD',
      ]) {
        expect(
          isRepeatEligibleKeyId(id),
          isFalse,
          reason: '$id must NOT auto-repeat — a hold does nothing extra',
        );
      }
    });

    test('the eligible Set is explicit and matches the predicate', () {
      // The Set is the single source of truth for the predicate.
      for (final id in kRepeatEligibleKeyIds) {
        expect(isRepeatEligibleKeyId(id), isTrue);
      }
      // An unknown id is never eligible.
      expect(isRepeatEligibleKeyId('keyDoesNotExist'), isFalse);
    });

    test('every eligible id actually exists in the default layout', () {
      final layoutIds = kDefaultKeybarKeys.map((k) => k.id).toSet();
      for (final id in kRepeatEligibleKeyIds) {
        expect(
          layoutIds,
          contains(id),
          reason: 'eligible id $id must be a real key on the bar',
        );
      }
    });
  });

  group('KeyRepeatController timer lifecycle (#732, fakeAsync)', () {
    test('no tick fires before the initial delay elapses', () {
      fakeAsync((async) {
        var ticks = 0;
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() => ticks++);
        // Just shy of the initial delay — nothing yet.
        async.elapse(const Duration(milliseconds: 399));
        expect(ticks, 0, reason: 'a held key must not repeat before the delay');
        c.stop();
        async.flushTimers();
      });
    });

    test('after the initial delay, exactly one tick fires per interval', () {
      fakeAsync((async) {
        var ticks = 0;
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() => ticks++);

        // Cross the initial delay → first tick.
        async.elapse(const Duration(milliseconds: 400));
        expect(ticks, 1, reason: 'first repeat fires at the initial delay');

        // Each subsequent interval → exactly one more tick.
        async.elapse(const Duration(milliseconds: 60));
        expect(ticks, 2);
        async.elapse(const Duration(milliseconds: 60));
        expect(ticks, 3);

        // Five more intervals → five more ticks.
        async.elapse(const Duration(milliseconds: 60 * 5));
        expect(ticks, 8, reason: 'one tick per interval, steady cadence');

        c.stop();
        async.flushTimers();
      });
    });

    test('stop() before the initial delay = ZERO ticks (quick tap)', () {
      fakeAsync((async) {
        var ticks = 0;
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() => ticks++);
        // Finger lifts after 120ms — a normal tap.
        async.elapse(const Duration(milliseconds: 120));
        c.stop();
        // Let any (cancelled) timers settle.
        async.elapse(const Duration(milliseconds: 1000));
        expect(
          ticks,
          0,
          reason:
              'a quick tap must never trigger a repeat tick (no double-send)',
        );
        async.flushTimers();
      });
    });

    test('stop() during the repeat phase halts further ticks immediately', () {
      fakeAsync((async) {
        var ticks = 0;
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() => ticks++);
        async.elapse(const Duration(milliseconds: 400 + 60 * 3));
        final atStop = ticks;
        expect(atStop, 4, reason: 'initial + 3 interval ticks');
        c.stop();
        // Plenty of time passes — no more ticks after release.
        async.elapse(const Duration(milliseconds: 1000));
        expect(ticks, atStop, reason: 'release stops repeat immediately');
        async.flushTimers();
      });
    });

    test('stop() cleans up all timers (none pending afterward)', () {
      fakeAsync((async) {
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() {});
        async.elapse(const Duration(milliseconds: 400 + 60 * 2));
        c.stop();
        expect(
          async.pendingTimers,
          isEmpty,
          reason: 'no leaked timers after stop()',
        );
      });
    });

    test('stop() is idempotent and safe before start / twice', () {
      fakeAsync((async) {
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        // Safe with nothing started.
        c.stop();
        c.start(() {});
        async.elapse(const Duration(milliseconds: 500));
        c.stop();
        c.stop(); // double stop — must not throw.
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('start() while already running restarts cleanly (no leak)', () {
      fakeAsync((async) {
        var ticks = 0;
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() => ticks++);
        async.elapse(const Duration(milliseconds: 450)); // 1 tick in
        // A fresh pointer-down restarts — old timers must be cancelled, not
        // accumulated.
        c.start(() => ticks++);
        async.elapse(const Duration(milliseconds: 400));
        // Only ONE controller's worth of cadence — not two overlapping.
        expect(
          ticks,
          2,
          reason: 'restart cancels the prior schedule; no doubled cadence',
        );
        c.stop();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('repeat tick reuses the per-key send (#732)', () {
    test('each tick invokes the supplied send callback once', () {
      // The widget passes a tick callback that runs the SAME byte-send path a
      // single tap uses; the controller must call it exactly once per tick.
      fakeAsync((async) {
        final sent = <int>[];
        var n = 0;
        final c = KeyRepeatController(
          initialDelay: const Duration(milliseconds: 400),
          interval: const Duration(milliseconds: 60),
        );
        c.start(() => sent.add(++n));
        async.elapse(const Duration(milliseconds: 400 + 60 * 4));
        c.stop();
        // 1 initial + 4 interval ticks, each exactly once, in order.
        expect(sent, equals([1, 2, 3, 4, 5]));
        async.flushTimers();
      });
    });
  });
}
