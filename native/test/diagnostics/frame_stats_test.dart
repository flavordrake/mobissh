// Unit tests for the #1135 frame-time + viewport telemetry.
//
// The whole point of this module is that it must still be readable AFTER a
// two-minute stall: the connect ring (600 events) has already evicted the
// onset by the time the owner taps Feedback, so a frame ring that only holds
// the last N frames of a burst would be equally useless. These tests pin:
//   1. the aggregates are correct across FAR more frames than anything is
//      retained for (histogram-backed, lifetime),
//   2. the worst offenders survive with their timestamps AND the context
//      captured at THEIR frame (not at snapshot time),
//   3. the retained list is bounded,
//   4. the viewport / session-load publishers report what was published.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/frame_stats.dart';

void main() {
  group('FrameStatsRecorder aggregates', () {
    test('are exact across far more frames than the worst list holds', () {
      final r = FrameStatsRecorder(worstCapacity: 5);
      // 900 healthy frames (8ms) + 100 janky ones (50ms), interleaved so no
      // ordering trick can produce the right answer by accident.
      for (var i = 0; i < 1000; i++) {
        final janky = i % 10 == 0;
        r.recordFrame(
          buildMs: janky ? 30 : 5,
          rasterMs: janky ? 20 : 3,
          tsMs: 1000 + i,
        );
      }

      final snap = r.snapshot();
      expect(snap['frames'], 1000);
      expect(snap['p50Ms'], 8.0, reason: 'the median frame is a healthy 8ms');
      expect(
        snap['p95Ms'],
        50.0,
        reason: '10% of frames are 50ms, so p95 lands in the janky bucket',
      );
      expect(snap['maxMs'], 50.0);
      expect(snap['maxBuildMs'], 30.0);
      expect(snap['maxRasterMs'], 20.0);
      expect(snap['over16'], 100);
      expect(snap['over32'], 100);
      expect(snap['over100'], 0);
      expect(snap['spanMs'], 999);
      // Bounded: the retained evidence list never grows with frame count.
      expect((snap['worst']! as List<Object?>).length, 5);
    });

    test('counts each jank threshold independently', () {
      final r = FrameStatsRecorder(worstCapacity: 3);
      for (final ms in <double>[4, 17, 33, 120, 900]) {
        r.recordFrame(buildMs: ms, rasterMs: 0, tsMs: 0);
      }
      final snap = r.snapshot();
      expect(snap['over16'], 4, reason: '17/33/120/900 are all >= 16ms');
      expect(snap['over32'], 3);
      expect(snap['over100'], 2);
    });

    test('a >=1s stall frame keeps its EXACT max and does not skew p50', () {
      final r = FrameStatsRecorder(worstCapacity: 2);
      for (var i = 0; i < 99; i++) {
        r.recordFrame(buildMs: 6, rasterMs: 2, tsMs: i);
      }
      // The frame a "one and a half second" stall would produce.
      r.recordFrame(buildMs: 1200.5, rasterMs: 340.0, tsMs: 99);

      final snap = r.snapshot();
      expect(snap['frames'], 100);
      expect(snap['p50Ms'], 8.0);
      expect(
        snap['maxMs'],
        1540.5,
        reason: 'the overflow bucket must not lose the real maximum',
      );
      expect(r.percentileMs(1.0), 1540.5);
      expect(snap['over100'], 1);
    });

    test('empty recorder snapshots cleanly (no frames yet)', () {
      final snap = FrameStatsRecorder().snapshot();
      expect(snap['frames'], 0);
      expect(snap['p50Ms'], 0);
      expect(snap['maxMs'], 0);
      expect(snap['worst'], isEmpty);
    });
  });

  group('FrameStatsRecorder worst offenders', () {
    test('retains the N worst frames, worst first, with timestamps', () {
      final r = FrameStatsRecorder(worstCapacity: 3);
      final durations = <double>[5, 210, 8, 1500, 7, 120, 6, 300, 9];
      for (var i = 0; i < durations.length; i++) {
        r.recordFrame(buildMs: durations[i], rasterMs: 0, tsMs: 5000 + i);
      }

      final worst = r.worst;
      expect(worst.map((s) => s.totalMs).toList(), <double>[1500, 300, 210]);
      expect(
        worst.map((s) => s.tsMs).toList(),
        <int>[5003, 5007, 5001],
        reason: 'each retained frame keeps the wall clock it happened at',
      );
      final json = worst.first.toJson();
      expect(json['tsMs'], 5003);
      expect(json['totalMs'], 1500.0);
      expect(json['ts'], contains('T'), reason: 'human-readable stamp too');
    });

    test('stamps the context captured AT that frame, not at snapshot time', () {
      var tick = 0;
      final r = FrameStatsRecorder(
        worstCapacity: 2,
        contextProbe: () => <String, Object?>{'tick': tick},
      );
      tick = 1;
      r.recordFrame(buildMs: 500, rasterMs: 0, tsMs: 1); // worst
      tick = 2;
      r.recordFrame(buildMs: 200, rasterMs: 0, tsMs: 2); // second worst
      tick = 3;
      r.recordFrame(buildMs: 4, rasterMs: 0, tsMs: 3); // healthy, not retained
      tick = 99; // snapshot-time context must NOT overwrite the samples

      final snap = r.snapshot();
      final worst = snap['worst']! as List<Object?>;
      expect((worst[0]! as Map<String, Object?>)['tick'], 1);
      expect((worst[1]! as Map<String, Object?>)['tick'], 2);
      expect(
        (snap['now']! as Map<String, Object?>)['tick'],
        99,
        reason: 'the capture-time context rides separately, as `now`',
      );
    });

    test('a long burst of ever-worsening frames stays bounded', () {
      final r = FrameStatsRecorder(worstCapacity: 4);
      for (var i = 1; i <= 2000; i++) {
        r.recordFrame(buildMs: i.toDouble(), rasterMs: 0, tsMs: i);
      }
      expect(r.worst.length, 4);
      expect(
        r.worst.map((s) => s.totalMs).toList(),
        <double>[2000, 1999, 1998, 1997],
      );
      expect(r.frameCount, 2000);
    });
  });

  group('viewport + session-load publishers', () {
    setUp(resetFrameStatsForTest);
    tearDown(resetFrameStatsForTest);

    test('terminal geometry is published per session and cleared on dispose', () {
      recordTerminalViewport(
        sessionId: 'fd-dev:22',
        boxWidth: 405,
        boxHeight: 594,
        cols: 59,
        rows: 33,
        tsMs: 42,
      );
      recordTerminalViewport(
        sessionId: 'raserver:22',
        boxWidth: 405,
        boxHeight: 594,
        cols: 55,
        rows: 33,
        tsMs: 43,
      );

      final terminals =
          defaultFrameContextProbe()['terminals']! as List<Object?>;
      expect(terminals.length, 2, reason: 'multi-session load is visible');
      final first = terminals.first! as Map<String, Object?>;
      expect(first['sid'], 'fd-dev:22');
      expect(first['h'], 594.0);
      expect(first['cols'], 59);
      expect(first['rows'], 33);

      clearTerminalViewport('fd-dev:22');
      expect(
        (defaultFrameContextProbe()['terminals']! as List<Object?>).length,
        1,
      );
    });

    test('streaming counts only sessions with output inside the window', () {
      recordSessionLoad(live: 5, connected: 4);
      const now = 10000000;
      noteSessionOutput('a', tsMs: now - 100);
      noteSessionOutput('b', tsMs: now - 1900);
      noteSessionOutput('c', tsMs: now - 30000); // idle
      noteSessionOutput('d', tsMs: now - 500);

      final load = sessionLoadSnapshot(nowMs: now);
      expect(load['live'], 5);
      expect(load['connected'], 4);
      expect(load['streaming'], 3, reason: 'c last streamed 30s ago');
    });

    test('closing a session drops its streaming record', () {
      const now = 500000;
      noteSessionOutput('a', tsMs: now);
      expect(sessionLoadSnapshot(nowMs: now)['streaming'], 1);
      clearSessionOutput('a');
      expect(sessionLoadSnapshot(nowMs: now)['streaming'], 0);
    });

    test('the summary line carries the numbers a reader triages on', () {
      final r = FrameStatsRecorder(
        worstCapacity: 2,
        contextProbe: () => <String, Object?>{
          'viewport': <String, Object?>{'screenH': 874.0, 'insetBottom': 280.0},
          'sessions': <String, Object?>{'live': 5, 'streaming': 4},
        },
      );
      r.recordFrame(buildMs: 900, rasterMs: 100, tsMs: 1);
      r.recordFrame(buildMs: 4, rasterMs: 2, tsMs: 2);

      final line = r.summaryLine();
      expect(line, contains('frames=2'));
      expect(line, contains('max=1000.0ms'));
      expect(line, contains('over100=1'));
      expect(line, contains('insetBottom'));
      expect(line, contains('streaming'));
    });
  });
}
