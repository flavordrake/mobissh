// Unit tests for the no-op PTY resize guard on `SshSessionProxy.sendResize`
// (#848).
//
// The keyboard-hide resize STORM (#848) was driven by the fit/resize path
// re-emitting IDENTICAL (cols, rows) to the PTY on every keyboard-animation
// frame, for every mounted session. Each identical resize made tmux redraw —
// the duplicated/ghosted content — and flooded the connect ring with
// `send resize sid=… → transport` lines that drowned every other event.
//
// The fix dedupes at the EMISSION point: `sendResize` only forwards to the
// gateway when the dimensions ACTUALLY CHANGED from the last grid sent for this
// session. A `force` bypass keeps the #666 connect-resync (which deliberately
// re-sends the SAME dims to re-sync a stale remote) working.
//
// These tests run against an `InMemoryGatewayPair`: the proxy's `sendResize`
// pushes `SshResizeCommand`s onto the UI→task channel, which we observe on the
// task side. Per-session independence is exercised with two proxies that share
// the channel but carry different session ids.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

/// Collects the (cols, rows) of every `resize` command that reached the task
/// side of the pair, in order. SFTP/connect/etc. payloads are ignored.
List<({String sid, int cols, int rows})> _resizes(
  List<Map<String, dynamic>> seen,
) {
  return [
    for (final p in seen)
      if (p['kind'] == SshTaskCommandKind.resize.name)
        (
          sid: p['sessionId'] as String,
          cols: p['cols'] as int,
          rows: p['rows'] as int,
        ),
  ];
}

void main() {
  late InMemoryGatewayPair pair;
  late List<Map<String, dynamic>> seen;

  setUp(() {
    pair = InMemoryGatewayPair();
    seen = <Map<String, dynamic>>[];
    pair.taskSide.incoming.listen(seen.add);
  });

  tearDown(() async {
    await pair.dispose();
  });

  // Pump the in-memory channel: the broadcast stream delivers asynchronously,
  // so we yield the event loop before asserting on what the task side saw.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'identical dimensions sent twice emit only ONE resize (no-op guard)',
    () async {
      final proxy = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      proxy.sendResize(80, 24);
      proxy.sendResize(80, 24);
      proxy.sendResize(80, 24);
      await settle();

      final r = _resizes(seen);
      expect(
        r.length,
        1,
        reason:
            'three IDENTICAL resizes must collapse to one PTY write — the #848 '
            'storm is half identical no-ops that make tmux redraw. Got: $r',
      );
      expect(r.single.cols, 80);
      expect(r.single.rows, 24);
    },
  );

  test('a CHANGED dimension after a no-op run is emitted', () async {
    final proxy = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
    addTearDown(proxy.dispose);

    proxy.sendResize(80, 24); // emit
    proxy.sendResize(80, 24); // drop (no-op)
    proxy.sendResize(80, 30); // emit (rows changed)
    proxy.sendResize(90, 30); // emit (cols changed)
    proxy.sendResize(90, 30); // drop (no-op)
    await settle();

    final r = _resizes(seen);
    expect(
      r.map((e) => '${e.cols}x${e.rows}').toList(),
      ['80x24', '80x30', '90x30'],
      reason: 'only real dimension changes reach the PTY (#848). Got: $r',
    );
  });

  test(
    'force: true re-emits identical dimensions (the #666 connect-resync path)',
    () async {
      final proxy = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      proxy.sendResize(80, 24); // emit
      proxy.sendResize(80, 24); // drop (no-op)
      proxy.sendResize(80, 24, force: true); // emit — forced resync
      await settle();

      final r = _resizes(seen);
      expect(
        r.length,
        2,
        reason:
            'force must bypass the no-op guard so a stale remote can be '
            're-synced with the SAME dims (#666). Got: $r',
      );
      expect(r.every((e) => e.cols == 80 && e.rows == 24), isTrue);
    },
  );

  test('the no-op guard is PER-SESSION — sessions never cross-suppress',
      () async {
    final s1 = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
    final s2 = SshSessionProxy(sessionId: 's2', gateway: pair.uiSide);
    addTearDown(s1.dispose);
    addTearDown(s2.dispose);

    // Both sessions settle on 80x24. Each must emit its OWN first resize even
    // though the dims are identical — the last-sent grid is tracked per proxy,
    // so s2's first 80x24 is NOT suppressed by s1's.
    s1.sendResize(80, 24); // emit (s1)
    s2.sendResize(80, 24); // emit (s2 — independent)
    s1.sendResize(80, 24); // drop (s1 no-op)
    s2.sendResize(80, 24); // drop (s2 no-op)
    await settle();

    final r = _resizes(seen);
    expect(
      r.where((e) => e.sid == 's1').length,
      1,
      reason: 's1 must emit exactly one resize. Got: $r',
    );
    expect(
      r.where((e) => e.sid == 's2').length,
      1,
      reason:
          's2 must emit its OWN first resize — it must NOT be suppressed by '
          's1 having already sent the same dims (per-session guard). Got: $r',
    );
  });

  group('telemetry hygiene (#848/#836)', () {
    test('the gateway resize label carries cols×rows so a real change is '
        'visible and identical lines collapse', () {
      final label = gwLabel(
        const SshResizeCommand(sessionId: 'fd-dev:22:u:1', cols: 80, rows: 24)
            .toJson(),
      );
      // The session handle (host:port) AND the grid must both be present: the
      // grid is what tells a reader a resize actually CHANGED the size, and two
      // identical resize lines now read identically → ctrace ×N collapse.
      expect(label, contains('sid=fd-dev:22'));
      expect(
        label,
        contains('80x24'),
        reason:
            'the resize log label must carry the grid dims (#848) — without '
            'them the connect ring can not show what changed and consecutive '
            'identical resizes do not collapse. Got: "$label"',
      );
    });

    test('a non-resize payload label is unchanged (no spurious dims)', () {
      final label = gwLabel(<String, dynamic>{
        'kind': 'input',
        'sessionId': 'fd-dev:22:u:1',
      });
      expect(label, 'input sid=fd-dev:22');
    });
  });
}
