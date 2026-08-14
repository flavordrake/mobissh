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

  group('sent-SGR ring', () {
    test('records a synthesized mouse/wheel SGR report', () {
      final rec = SessionByteRecorder();
      // A window-switch wheel-down report: CSI<65;1;28M
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<65;1;28M')));
      final snap = rec.snapshotSentSgrTrace();
      expect(snap, hasLength(1));
      final decoded = utf8.decode(base64Decode(snap.single['b64'] as String));
      expect(decoded, '\x1b[<65;1;28M');
      expect(snap.single['tMs'], isA<int>());
    });

    test('does NOT record a typed keystroke / password line', () {
      final rec = SessionByteRecorder();
      // A typed password at a prompt flows through the SAME send seam. The
      // filter must drop it entirely — it is NOT an SGR-mouse report, so it
      // never enters the ring. rules/security.md: typed secrets never recorded.
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('hunter2\r')));
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('ls -la\n')));
      // Plain Enter / control keys are not mouse reports either.
      rec.recordSentSgr(Uint8List.fromList([0x03])); // Ctrl-C
      expect(rec.snapshotSentSgrTrace(), isEmpty);
    });

    test('records ONLY the SGR-mouse part is irrelevant — whole chunk in, but '
        'keystroke chunks dropped; mouse chunks kept', () {
      final rec = SessionByteRecorder();
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('password123'))); // drop
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<0;5;10M'))); // keep (press)
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<0;5;10m'))); // keep (release)
      final snap = rec.snapshotSentSgrTrace();
      expect(snap, hasLength(2));
      final texts = snap
          .map((e) => utf8.decode(base64Decode(e['b64'] as String)))
          .toList();
      expect(texts, ['\x1b[<0;5;10M', '\x1b[<0;5;10m']);
    });

    test('evicts oldest sent-SGR events past the count cap', () {
      final rec = SessionByteRecorder(maxSentSgrEvents: 3);
      for (var i = 0; i < 6; i++) {
        rec.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<65;$i;1M')));
      }
      final snap = rec.snapshotSentSgrTrace();
      expect(snap, hasLength(3));
      final texts = snap
          .map((e) => utf8.decode(base64Decode(e['b64'] as String)))
          .toList();
      // Newest three survive.
      expect(texts, [
        '\x1b[<65;3;1M',
        '\x1b[<65;4;1M',
        '\x1b[<65;5;1M',
      ]);
    });

    test('snapshot scrubs the sent-SGR stream (defense in depth)', () {
      final rec = SessionByteRecorder();
      // Mouse reports never carry credentials, but the snapshot scrubs as
      // defense in depth like the output ring. A report is kept; a scrub that
      // changes nothing preserves the exact bytes.
      rec.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<32;7;3M')));
      final snap = rec.snapshotSentSgrTrace();
      expect(
        utf8.decode(base64Decode(snap.single['b64'] as String)),
        '\x1b[<32;7;3M',
      );
    });

    test('active registry routes the sent-SGR snapshot to the active session', () {
      final a = registerByteRecorder('s-a');
      final b = registerByteRecorder('s-b');
      a.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<64;1;1M')));
      b.recordSentSgr(Uint8List.fromList(utf8.encode('\x1b[<65;1;1M')));

      setActiveByteRecorder('s-a');
      expect(
        utf8.decode(
          base64Decode(activeSentSgrTraceSnapshot().single['b64'] as String),
        ),
        '\x1b[<64;1;1M',
      );
      setActiveByteRecorder('s-b');
      expect(
        utf8.decode(
          base64Decode(activeSentSgrTraceSnapshot().single['b64'] as String),
        ),
        '\x1b[<65;1;1M',
      );
    });

    test('sent-SGR snapshot is empty (not null) when no session is active', () {
      setActiveByteRecorder(null);
      expect(activeSentSgrTraceSnapshot(), isEmpty);
    });
  });

  group('O(1) Queue eviction', () {
    test('byte ring preserves FIFO order across eviction', () {
      final rec = SessionByteRecorder(maxBytes: 100, maxEvents: 1000);
      // 8 chunks of 25 bytes; cap 100 keeps the newest ~4.
      for (var i = 0; i < 8; i++) {
        rec.recordBytes(Uint8List(25)..fillRange(0, 25, i));
      }
      final snap = rec.snapshotByteTrace();
      // The surviving chunks are a contiguous newest-first suffix, in order.
      final firstBytes = snap
          .map((e) => base64Decode(e['b64'] as String).first)
          .toList();
      for (var i = 1; i < firstBytes.length; i++) {
        expect(firstBytes[i], greaterThan(firstBytes[i - 1]));
      }
      // Last is the newest chunk (filled with 7).
      expect(firstBytes.last, 7);
    });

    test('byteTotal accounting stays consistent after Queue eviction', () {
      final rec = SessionByteRecorder(maxBytes: 100, maxEvents: 1000);
      for (var i = 0; i < 10; i++) {
        rec.recordBytes(Uint8List(30)..fillRange(0, 30, i));
      }
      final snap = rec.snapshotByteTrace();
      var total = 0;
      for (final ev in snap) {
        total += base64Decode(ev['b64'] as String).length;
      }
      expect(total, lessThanOrEqualTo(100));
      // Reported byteTotal matches the sum of surviving chunk lengths.
      expect(rec.debugByteTotal, total);
    });

    test('scroll ring preserves FIFO order across Queue eviction', () {
      final rec = SessionByteRecorder(maxScrollEvents: 4);
      for (var i = 0; i < 9; i++) {
        rec.recordScroll(i * 10);
      }
      final offsets = rec
          .snapshotScrollTrace()
          .map((e) => e['offset'] as int)
          .toList();
      expect(offsets, [50, 60, 70, 80]);
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

  // #1072: terminal AUTO-REPLY ring — the DA/DSR/CPR/OSC responses the terminal
  // itself generates (teed from flterm's onWritePty). Same eviction/scrub
  // discipline as the byte ring, plus a coarse `kind` tag per event.
  group('term-reply ring', () {
    test('records {tMs, b64, kind} that round-trips the exact bytes', () {
      final rec = SessionByteRecorder();
      rec.recordTermReply(Uint8List.fromList(utf8.encode('\x1b[?62c')));
      final snap = rec.snapshotTermReplyTrace();
      expect(snap, hasLength(1));
      final ev = snap.single;
      expect(ev['tMs'], isA<int>());
      expect(utf8.decode(base64Decode(ev['b64'] as String)), '\x1b[?62c');
    });

    test('classifies replies by leading bytes', () {
      Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
      expect(termReplyKind(b('\x1b[?62c')), 'DA1');
      expect(termReplyKind(b('\x1b[>1;95;0c')), 'DA2');
      expect(termReplyKind(b('\x1b[8;24;80R')), 'CPR');
      expect(termReplyKind(b('\x1b[0n')), 'DSR');
      expect(termReplyKind(b('\x1b]11;rgb:0000/0000/0000\x1b\\')), 'OSC');
      expect(termReplyKind(b('plain')), 'other');
    });

    test('evicts oldest past the event cap', () {
      final rec = SessionByteRecorder(maxTermReplyEvents: 3);
      for (var i = 0; i < 6; i++) {
        rec.recordTermReply(Uint8List.fromList([0x1b, 0x5b, 0x30 + i, 0x6e]));
      }
      final snap = rec.snapshotTermReplyTrace();
      expect(snap, hasLength(3), reason: 'only the newest 3 survive the cap');
    });

    // #1109-A: the ring is constrained to a strict DA/DSR/CPR/XTVERSION
    // allowlist. A generic OSC / hook / other reply — which could carry
    // remote-supplied content verbatim — is DROPPED, never recorded.
    test('drops non-allowlisted replies (generic OSC / other)', () {
      final rec = SessionByteRecorder();
      // OSC carrying a secret-looking title — must NOT be recorded at all.
      rec.recordTermReply(
        Uint8List.fromList(utf8.encode('\x1b]0;token=SECRET123\x1b\\')),
      );
      // Arbitrary non-escape bytes — dropped.
      rec.recordTermReply(Uint8List.fromList(utf8.encode('plain output')));
      expect(rec.snapshotTermReplyTrace(), isEmpty);
    });

    test('records the allowlisted device replies (DA/CPR/DSR/XTVERSION)', () {
      final rec = SessionByteRecorder();
      rec.recordTermReply(Uint8List.fromList(utf8.encode('\x1b[?62c'))); // DA1
      rec.recordTermReply(Uint8List.fromList(utf8.encode('\x1b[>1;95;0c'))); // DA2
      rec.recordTermReply(Uint8List.fromList(utf8.encode('\x1b[8;24;80R'))); // CPR
      rec.recordTermReply(Uint8List.fromList(utf8.encode('\x1b[0n'))); // DSR
      rec.recordTermReply(Uint8List.fromList(utf8.encode('\x1bP>|xterm\x1b\\'))); // XTVERSION
      expect(rec.snapshotTermReplyTrace(), hasLength(5));
    });

    test('isAllowedTermReply accepts device replies, rejects OSC/other', () {
      Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
      expect(isAllowedTermReply(b('\x1b[?62c')), isTrue); // DA1
      expect(isAllowedTermReply(b('\x1b[>1;95;0c')), isTrue); // DA2
      expect(isAllowedTermReply(b('\x1b[8;24;80R')), isTrue); // CPR
      expect(isAllowedTermReply(b('\x1b[0n')), isTrue); // DSR
      expect(isAllowedTermReply(b('\x1bP>|xterm\x1b\\')), isTrue); // XTVERSION
      expect(isAllowedTermReply(b('\x1b]0;title\x1b\\')), isFalse); // OSC
      expect(isAllowedTermReply(b('plain')), isFalse); // other
    });

    test('active registry routes the term-reply snapshot to the active session',
        () {
      final a = registerByteRecorder('s-a');
      a.recordTermReply(Uint8List.fromList(utf8.encode('\x1b[?62c')));
      setActiveByteRecorder('s-a');
      expect(activeTermReplyTraceSnapshot(), hasLength(1));
      setActiveByteRecorder(null);
      expect(activeTermReplyTraceSnapshot(), isEmpty);
    });
  });
}
