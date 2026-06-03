// #699 — gesture-trace ring buffer: records, caps, collapses duplicates,
// snapshots, and renders SGR bytes printable. Mirrors the connect_trace.dart
// contract so a device repro of the Ghostty selection-offset bug carries the
// touch->cell mapping numbers off the phone.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/gesture_trace.dart';

void main() {
  setUp(clearGestureLog);
  tearDown(clearGestureLog);

  group('formatSgrForTrace — control bytes rendered printable', () {
    test('ESC (0x1b) becomes the literal text ESC', () {
      expect(formatSgrForTrace('\x1b[<0;5;3M'), 'ESC[<0;5;3M');
    });

    test('carriage return becomes \\r and no raw escape leaks', () {
      final out = formatSgrForTrace('\x1b[<0;1;1M\r');
      expect(out, 'ESC[<0;1;1M\\r');
      expect(out.contains('\x1b'), isFalse);
    });
  });

  group('formatGestureEvent — fixed k=v fields (#699)', () {
    test('renders every diagnostic field, cell + SGR present', () {
      final line = formatGestureEvent(
        type: 'longpress-start',
        dx: 109.0,
        dy: 174.0,
        width: 800.0,
        height: 600.0,
        cols: 80,
        rows: 24,
        col: 11,
        row: 11,
        sgr: '\x1b[<0;11;11M',
        mouseTracking: 'any',
        handledBy: 'overlay',
      );
      expect(line, contains('longpress-start'));
      expect(line, contains('pos=(109.0,174.0)'));
      expect(line, contains('size=(800.0,600.0)'));
      expect(line, contains('grid=80x24'));
      expect(line, contains('cell=(11,11)'));
      expect(line, contains('sgr=ESC[<0;11;11M'));
      expect(line, contains('mouse=any'));
      expect(line, contains('by=overlay'));
    });

    test('omitted cell/SGR render as - and none', () {
      final line = formatGestureEvent(
        type: 'tap',
        dx: 5.0,
        dy: 5.0,
        width: 100.0,
        height: 100.0,
        cols: 80,
        rows: 24,
        mouseTracking: 'none',
        handledBy: 'flterm',
      );
      expect(line, contains('cell=-'));
      expect(line, contains('sgr=none'));
    });
  });

  group('gestureLog ring buffer — record / snapshot (#699)', () {
    test('starts empty', () {
      expect(gestureLogSnapshot(), isEmpty);
    });

    test('records an event and exposes it via the snapshot (newest last)', () {
      gevent(
        type: 'tap',
        dx: 1,
        dy: 2,
        width: 100,
        height: 100,
        cols: 80,
        rows: 24,
        col: 1,
        row: 1,
        sgr: '\x1b[<0;1;1M',
        mouseTracking: 'any',
        handledBy: 'overlay',
      );
      final snap = gestureLogSnapshot();
      expect(snap.length, 1);
      expect(snap.single, contains('tap'));
      expect(snap.single, contains('cell=(1,1)'));
      // ESC must be escaped — no raw control byte in the ring.
      expect(snap.single.contains('\x1b'), isFalse);
    });

    test('the snapshot is an unmodifiable copy', () {
      gtrace('x');
      final snap = gestureLogSnapshot();
      expect(() => snap.add('y'), throwsUnsupportedError);
    });

    test('collapses consecutive identical lines into ×N', () {
      gtrace('longpress-move pos=(10.0,10.0)');
      gtrace('longpress-move pos=(10.0,10.0)');
      gtrace('longpress-move pos=(10.0,10.0)');
      final snap = gestureLogSnapshot();
      expect(snap.length, 1);
      expect(snap.single, contains('(×3)'));
    });

    test('a changed line starts a fresh entry (no collapse)', () {
      gtrace('a');
      gtrace('b');
      gtrace('a');
      final snap = gestureLogSnapshot();
      expect(snap.length, 3);
    });

    test('caps at gestureLogCapacity, dropping oldest', () {
      for (var i = 0; i < gestureLogCapacity + 25; i++) {
        gtrace('line-$i');
      }
      final snap = gestureLogSnapshot();
      expect(snap.length, gestureLogCapacity);
      // Oldest dropped: the very first line is gone; the last is retained.
      expect(snap.first.contains('line-0 '), isFalse);
      expect(snap.last, contains('line-${gestureLogCapacity + 24}'));
    });

    test('clearGestureLog empties the ring and resets collapse state', () {
      gtrace('z');
      gtrace('z');
      clearGestureLog();
      expect(gestureLogSnapshot(), isEmpty);
      // After clear, a repeat of the previously-collapsed line starts fresh.
      gtrace('z');
      expect(gestureLogSnapshot().single, isNot(contains('×')));
    });
  });

  group('gestureLog listenable notifies on append/clear', () {
    test('the ValueListenable updates when an event is recorded', () {
      final ValueListenable<List<String>> log = gestureLog;
      var notifications = 0;
      void listener() => notifications++;
      log.addListener(listener);
      addTearDown(() => log.removeListener(listener));

      gtrace('one');
      gtrace('two');
      expect(notifications, greaterThanOrEqualTo(2));
      expect(log.value.length, 2);
    });
  });
}
