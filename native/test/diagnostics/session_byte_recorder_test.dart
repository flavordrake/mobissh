// Unit tests for the in-app byte + scroll-event recorder (#790).
//
// The recorder is the replay-harness TRACE PRODUCER: a continuously-running,
// bounded, BACKWARD-looking ring that captures (a) the raw bytes written to the
// terminal and (b) scroll-offset events, per active session, so a captured
// trace can later be replayed (#791) to reproduce a scrollback-render bug.
//
// These tests lock the ring contract:
//   - byte ring evicts oldest past the byte cap;
//   - byte ring evicts oldest past the age cap;
//   - relative-ms timestamps are monotonic non-decreasing;
//   - b64 round-trips the exact bytes;
//   - the snapshot scrubs credential-looking lines out of the byte stream;
//   - scroll ring evicts oldest past the count cap, timestamps monotonic;
//   - the active-recorder registry routes snapshots to the active session.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/session_byte_recorder.dart';

void main() {
  setUp(clearAllByteRecorders);
  tearDown(clearAllByteRecorders);

  group('byte ring', () {
    test('appends bytes as {tMs, b64} that round-trips', () {
      final rec = SessionByteRecorder();
      rec.recordBytes(Uint8List.fromList([0, 1, 2, 250, 255]));
      final snap = rec.snapshotByteTrace();
      expect(snap, hasLength(1));
      final ev = snap.single;
      expect(ev['tMs'], isA<int>());
      final decoded = base64Decode(ev['b64'] as String);
      expect(decoded, [0, 1, 2, 250, 255]);
    });

    test('evicts oldest chunks once the byte cap is exceeded', () {
      // Cap small so a few chunks overflow it deterministically.
      final rec = SessionByteRecorder(maxBytes: 100, maxEvents: 1000);
      // 8 chunks of 25 bytes = 200 bytes; cap 100 → only the newest ~100 survive.
      for (var i = 0; i < 8; i++) {
        rec.recordBytes(Uint8List(25)..fillRange(0, 25, i));
      }
      final snap = rec.snapshotByteTrace();
      var total = 0;
      for (final ev in snap) {
        total += base64Decode(ev['b64'] as String).length;
      }
      expect(total, lessThanOrEqualTo(100));
      // The NEWEST chunk (filled with 7) must still be present — backward-looking.
      final last = base64Decode(snap.last['b64'] as String);
      expect(last.every((b) => b == 7), isTrue);
    });

    test('evicts chunks older than the age cap', () {
      var clock = 0;
      final rec = SessionByteRecorder(
        maxAge: const Duration(milliseconds: 1000),
        nowMs: () => clock,
      );
      rec.recordBytes(Uint8List.fromList([1])); // t=0
      clock = 500;
      rec.recordBytes(Uint8List.fromList([2])); // t=500
      clock = 2000; // now 2000ms; the t=0 chunk is 2000ms old → evicted
      rec.recordBytes(Uint8List.fromList([3])); // t=2000
      final snap = rec.snapshotByteTrace();
      // Only chunks within 1000ms of the latest (2000) survive: t=2000 (and the
      // t=500 chunk is 1500ms old → evicted too).
      final values = snap
          .map((e) => base64Decode(e['b64'] as String).first)
          .toList();
      expect(values, isNot(contains(1)));
      expect(values, contains(3));
    });

    test('relative-ms timestamps are monotonic non-decreasing', () {
      var clock = 0;
      final rec = SessionByteRecorder(nowMs: () => clock);
      rec.recordBytes(Uint8List.fromList([1]));
      clock = 10;
      rec.recordBytes(Uint8List.fromList([2]));
      clock = 10; // same instant
      rec.recordBytes(Uint8List.fromList([3]));
      final ts = rec.snapshotByteTrace().map((e) => e['tMs'] as int).toList();
      for (var i = 1; i < ts.length; i++) {
        expect(ts[i], greaterThanOrEqualTo(ts[i - 1]));
      }
    });

    test('snapshot scrubs credential-looking lines out of the byte stream', () {
      final rec = SessionByteRecorder();
      // Terminal OUTPUT may echo a secret (e.g. a pasted token, a sudo prompt
      // echo). rules/security.md: it must NOT leave the device.
      rec.recordBytes(
        Uint8List.fromList(utf8.encode('login ok\npassword=hunter2\n')),
      );
      final snap = rec.snapshotByteTrace();
      final allText = snap
          .map((e) => utf8.decode(base64Decode(e['b64'] as String)))
          .join();
      expect(allText.contains('hunter2'), isFalse);
      expect(allText.contains('[REDACTED]'), isTrue);
    });
  });

  group('scroll ring', () {
    test('appends scroll offsets as {tMs, offset}', () {
      var clock = 0;
      final rec = SessionByteRecorder(nowMs: () => clock);
      rec.recordScroll(0);
      clock = 16;
      rec.recordScroll(120);
      final snap = rec.snapshotScrollTrace();
      expect(snap, hasLength(2));
      expect(snap.first['offset'], 0);
      expect(snap.last['offset'], 120);
      expect(snap.last['tMs'], 16);
    });

    test('evicts oldest scroll events past the count cap', () {
      final rec = SessionByteRecorder(maxScrollEvents: 3);
      for (var i = 0; i < 6; i++) {
        rec.recordScroll(i * 10);
      }
      final snap = rec.snapshotScrollTrace();
      expect(snap, hasLength(3));
      // Newest three offsets survive (30,40,50).
      expect(snap.map((e) => e['offset']).toList(), [30, 40, 50]);
    });

    test('records grid {cols,rows} and resizes', () {
      final rec = SessionByteRecorder();
      rec.recordGrid(80, 24);
      expect(rec.grid(), {'cols': 80, 'rows': 24});
      rec.recordGrid(120, 40);
      expect(rec.grid(), {'cols': 120, 'rows': 40});
    });
  });

  group('active recorder registry', () {
    test('snapshots route to the registered active session', () {
      final a = registerByteRecorder('session-a');
      final b = registerByteRecorder('session-b');
      a.recordBytes(Uint8List.fromList([1]));
      b.recordBytes(Uint8List.fromList([2, 3]));

      setActiveByteRecorder('session-a');
      expect(activeByteTraceSnapshot(), hasLength(1));
      expect(base64Decode(activeByteTraceSnapshot().single['b64'] as String), [
        1,
      ]);

      setActiveByteRecorder('session-b');
      expect(base64Decode(activeByteTraceSnapshot().single['b64'] as String), [
        2,
        3,
      ]);
    });

    test('snapshots are empty (not null) when no session is active', () {
      setActiveByteRecorder(null);
      expect(activeByteTraceSnapshot(), isEmpty);
      expect(activeScrollTraceSnapshot(), isEmpty);
      expect(activeGridSnapshot(), isNull);
    });

    test('unregister drops the recorder and clears active if it was it', () {
      registerByteRecorder('gone');
      setActiveByteRecorder('gone');
      unregisterByteRecorder('gone');
      expect(activeByteTraceSnapshot(), isEmpty);
      expect(activeGridSnapshot(), isNull);
    });
  });
}
