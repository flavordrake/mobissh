// Unit tests for the connect-trace ring buffer (#543).
//
// Exercises cap/ordering, listenable notification, and clear — all in the UI
// isolate against the in-memory buffer. No platform channels.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';

void main() {
  setUp(clearConnectLog);
  tearDown(clearConnectLog);

  test('ring buffer caps at capacity, dropping oldest and keeping newest', () {
    final n = connectLogCapacity;
    for (var i = 0; i < n + 10; i++) {
      ctrace('ui.test', 'line $i');
    }

    final lines = connectLog.value;
    expect(lines.length, n, reason: 'buffer must cap at $n');
    // Oldest 10 (line 0..9) dropped; newest retained at the end.
    expect(
      lines.first,
      contains('line 10'),
      reason: 'oldest lines should be dropped',
    );
    expect(
      lines.last,
      contains('line ${n + 9}'),
      reason: 'newest line should be retained at the end',
    );
  });

  test('lines are appended in call order, newest last', () {
    ctrace('ui.form', 'first');
    ctrace('ui.sessions', 'second');
    ctrace('ui.gw', 'third');

    final lines = connectLog.value;
    expect(lines.length, 3);
    expect(lines[0], contains('[ui.form] first'));
    expect(lines[1], contains('[ui.sessions] second'));
    expect(lines[2], contains('[ui.gw] third'));
  });

  test('line includes a HH:mm:ss.SSS timestamp and the where tag', () {
    ctrace('ui.proxy', 'hello');
    final line = connectLog.value.single;
    expect(
      line,
      matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[ui\.proxy\] hello$')),
    );
  });

  test('appending notifies listeners with a fresh list instance', () {
    var notifications = 0;
    void listener() => notifications++;
    connectLog.addListener(listener);
    addTearDown(() => connectLog.removeListener(listener));

    final before = connectLog.value;
    ctrace('ui.keepalive', 'ping');
    final after = connectLog.value;

    expect(notifications, 1, reason: 'a single append fires one notification');
    expect(
      identical(before, after),
      isFalse,
      reason: 'value must be a new list so ValueListenableBuilder rebuilds',
    );
  });

  test('consecutive identical lines collapse into one with a ×N count', () {
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');

    final lines = connectLog.value;
    expect(lines.length, 1, reason: 'three identical lines collapse to one');
    expect(lines.single, contains('[ui.gw] recv output (×3)'));
  });

  test('a different line breaks the run and starts a fresh entry', () {
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'send input');
    ctrace('ui.gw', 'recv output'); // same text, but run was broken

    final lines = connectLog.value;
    expect(lines.length, 3);
    expect(lines[0], contains('[ui.gw] recv output (×2)'));
    expect(lines[1], contains('[ui.gw] send input'));
    expect(
      lines[1],
      isNot(contains('×')),
      reason: 'a single occurrence has no count suffix',
    );
    expect(lines[2], contains('[ui.gw] recv output'));
    expect(lines[2], isNot(contains('×')));
  });

  test('collapsing notifies listeners so the count updates live', () {
    var notifications = 0;
    void listener() => notifications++;
    connectLog.addListener(listener);
    addTearDown(() => connectLog.removeListener(listener));

    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');

    expect(
      notifications,
      2,
      reason: 'each call notifies, even when collapsing the line',
    );
  });

  test('clearConnectLog empties the buffer and notifies', () {
    ctrace('ui.form', 'a');
    ctrace('ui.form', 'b');
    expect(connectLog.value, isNotEmpty);

    var cleared = false;
    void listener() => cleared = connectLog.value.isEmpty;
    connectLog.addListener(listener);
    addTearDown(() => connectLog.removeListener(listener));

    clearConnectLog();
    expect(connectLog.value, isEmpty);
    expect(cleared, isTrue);
  });

  group('lifecycle ring (#759)', () {
    test(
      'clifecycle appends to BOTH the lifecycle ring and the connect ring',
      () {
        clifecycle('task.host', 'resume-liveness: alive(recent-bytes)');

        expect(
          lifecycleLog.value.single,
          contains('resume-liveness: alive(recent-bytes)'),
        );
        expect(
          connectLog.value.single,
          contains('resume-liveness: alive(recent-bytes)'),
          reason: 'the event must also show in-context in the connect ring',
        );
      },
    );

    test('a lifecycle event SURVIVES the connect-ring churn', () {
      clifecycle(
        'task.host',
        'resume-liveness: STALE(no-bytes-after-nudge) '
            '→ reconnect',
      );
      // Flood the connect ring past its cap so the lifecycle line is evicted
      // from the connect ring — but the dedicated ring must still retain it.
      for (var i = 0; i < connectLogCapacity + 50; i++) {
        ctrace('ui.gw', 'recv $i');
      }

      expect(
        lifecycleLogSnapshot().join('\n'),
        contains('STALE(no-bytes-after-nudge)'),
        reason:
            'the dedicated ring must outlive the connect-ring churn — the '
            'whole point of #759 telemetry retention',
      );
    });

    test('clifecycle is never collapsed into a preceding ×N run', () {
      ctrace('ui.gw', 'recv output');
      ctrace('ui.gw', 'recv output');
      clifecycle('task.host', 'resume-liveness: ping-failed → reconnect');

      final lines = connectLog.value;
      expect(lines.last, contains('ping-failed → reconnect'));
      expect(lines.last, isNot(contains('×')));
    });

    test('clearConnectLog also clears the lifecycle ring', () {
      clifecycle('task.host', 'resume-liveness: alive(recent-bytes)');
      expect(lifecycleLog.value, isNotEmpty);
      clearConnectLog();
      expect(lifecycleLog.value, isEmpty);
    });
  });

  group('lifecycle forwarder (#766)', () {
    tearDown(() => lifecycleForwarder = null);

    test('clifecycle invokes the forwarder with the formatted line', () {
      final forwarded = <String>[];
      lifecycleForwarder = forwarded.add;

      clifecycle('task.host', 'resume-liveness: STALE → reconnect');

      expect(forwarded, hasLength(1));
      // The forwarded line is the SAME formatted line stored in the ring, so the
      // task-side timestamp is preserved across the boundary.
      expect(forwarded.single, lifecycleLog.value.single);
      expect(forwarded.single, contains('[task.host]'));
      expect(forwarded.single, contains('STALE → reconnect'));
    });

    test('ctrace does NOT invoke the lifecycle forwarder', () {
      final forwarded = <String>[];
      lifecycleForwarder = forwarded.add;

      ctrace('ui.gw', 'recv state');

      expect(
        forwarded,
        isEmpty,
        reason: 'only lifecycle events forward, not ordinary connect traces',
      );
    });

    test('a throwing forwarder never breaks clifecycle recording', () {
      lifecycleForwarder = (_) => throw StateError('boom');

      // Must not throw, and must still record locally.
      clifecycle('task.host', 'resume-liveness: alive(recent-bytes)');

      expect(
        lifecycleLog.value.single,
        contains('alive(recent-bytes)'),
        reason: 'a forwarder failure is swallowed; local capture is preserved',
      );
    });

    test(
      'recordLifecycleLine lands a pre-formatted line in BOTH rings verbatim',
      () {
        const line = '12:34:56.789 [task.ssh] probeLiveness: ping-failed';

        recordLifecycleLine(line);

        // Stored verbatim — NOT re-timestamped — so the originating isolate's
        // timestamp survives.
        expect(lifecycleLogSnapshot().single, line);
        expect(connectLog.value.single, line);
      },
    );

    test('recordLifecycleLine does NOT re-invoke the forwarder (no echo)', () {
      final forwarded = <String>[];
      lifecycleForwarder = forwarded.add;

      recordLifecycleLine('12:00:00.000 [task.host] alive');

      expect(
        forwarded,
        isEmpty,
        reason:
            'a forwarded line recorded on the receiving side must not bounce '
            'back across the boundary',
      );
    });

    test('recordLifecycleLine survives connect-ring churn', () {
      recordLifecycleLine('09:00:00.000 [task.host] STALE → reconnect');
      for (var i = 0; i < connectLogCapacity + 50; i++) {
        ctrace('ui.gw', 'recv $i');
      }

      expect(
        lifecycleLogSnapshot().join('\n'),
        contains('STALE → reconnect'),
        reason: 'the dedicated ring outlives the connect-ring churn',
      );
    });
  });

  group('control-mode trace ring + forwarder (#906)', () {
    tearDown(() => controlModeForwarder = null);

    test('cmtrace appends a [cc]-tagged line to the control-mode ring', () {
      cmtrace('attach sid=s entry=exec handshakeConfirmed=false');
      expect(controlModeLogSnapshot(), hasLength(1));
      expect(controlModeLogSnapshot().single, contains('[cc]'));
      expect(controlModeLogSnapshot().single, contains('entry=exec'));
    });

    test('cmtrace invokes the forwarder with the same formatted line', () {
      final forwarded = <String>[];
      controlModeForwarder = forwarded.add;
      cmtrace('gesture raw=tapStatusCol col=45 cols=90 → dropped(reason=no-window-known)');
      expect(forwarded, hasLength(1));
      expect(forwarded.single, controlModeLog.value.single);
      expect(forwarded.single, contains('no-window-known'));
    });

    test('cmtrace does NOT touch the connect or lifecycle rings', () {
      cmtrace('notif window-add @3');
      expect(connectLog.value, isEmpty);
      expect(lifecycleLog.value, isEmpty);
    });

    test('a throwing forwarder never breaks cmtrace recording', () {
      controlModeForwarder = (_) => throw StateError('boom');
      cmtrace('notif session-window-changed @1 (authoritative active)');
      expect(controlModeLog.value.single, contains('session-window-changed @1'));
    });

    test('recordControlModeLine lands a pre-formatted line verbatim', () {
      const line = '12:34:56.789 [cc] windowList @0(alpha) @1(bravo)';
      recordControlModeLine(line);
      expect(controlModeLogSnapshot().single, line);
    });

    test('recordControlModeLine does NOT re-invoke the forwarder (no echo)', () {
      final forwarded = <String>[];
      controlModeForwarder = forwarded.add;
      recordControlModeLine('12:00:00.000 [cc] attach handshakeConfirmed=true');
      expect(forwarded, isEmpty);
    });

    test('clearConnectLog also clears the control-mode ring', () {
      cmtrace('notif window-add @0');
      expect(controlModeLogSnapshot(), isNotEmpty);
      clearConnectLog();
      expect(controlModeLogSnapshot(), isEmpty);
    });

    test('the control-mode ring is bounded to controlModeLogCapacity', () {
      for (var i = 0; i < controlModeLogCapacity + 40; i++) {
        cmtrace('notif window-add @$i');
      }
      expect(controlModeLogSnapshot().length, controlModeLogCapacity);
    });
  });
}
