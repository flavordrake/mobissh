// SessionHost background snapshot gate + dirty-check + scrollback off the
// periodic payload (#806).
//
// The kept-alive task isolate emits an SshSnapshotEvent per session every 2s.
// Backgrounded, the UI is unbound and discards it, but the timer keeps firing
// — incl. a ~4KB scrollback decode shipped cross-isolate. This is the largest
// avoidable background-battery drain. The host now:
//   A. Stops the periodic timer on SshSetActiveCommand(active: false); restores
//      it + emits one fresh full snapshot on active: true.
//   B. Dirty-checks the periodic push: an unchanged session emits nothing.
//   C. Omits the scrollback tail from the PERIODIC payload; the on-demand
//      SshRequestSnapshotCommand response still carries it.
//
// Headless via InMemoryGatewayPair + a controller whose connect() is inert so
// the test owns the `connected` transition — no real socket.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

/// Controller whose real connect() is a no-op so the test owns the `connected`
/// transition without a socket/auth race.
class _NoConnectController extends SshSessionController {
  @override
  Future<void> connect(SshConnectParams params) async {}
}

/// Collects SshSnapshotEvent payloads the host sends to the UI side.
class _SnapshotCollector {
  _SnapshotCollector(TaskSshGateway uiSide) {
    _sub = uiSide.incoming.listen((p) {
      if (p['kind'] == SshTaskEventKind.snapshot.name) {
        events.add(SshTaskEvent.fromJson(p) as SshSnapshotEvent);
      }
    });
  }

  final List<SshSnapshotEvent> events = [];
  late final StreamSubscription<Map<String, dynamic>> _sub;

  Future<void> cancel() => _sub.cancel();
}

/// Stand up a host with one connected session. Returns the pair, host,
/// controller, and a snapshot collector. Uses a short snapshot interval so
/// periodic ticks are observable in real time.
Future<({InMemoryGatewayPair pair, SessionHost host, _SnapshotCollector col})>
_setup({Duration interval = const Duration(milliseconds: 20)}) async {
  const sid = 'h:22:u:1';
  late SshSessionController controller;
  final pair = InMemoryGatewayPair();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: () {
      controller = _NoConnectController();
      return controller;
    },
    snapshotInterval: interval,
  );
  pair.uiSide.send(
    const SshConnectCommand(
      sessionId: sid,
      host: 'h',
      port: 22,
      username: 'u',
      authJson: {'type': 'password', 'password': 'p'},
    ).toJson(),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
  controller.debugSetConnectedForTest(_params);
  await Future<void>.delayed(const Duration(milliseconds: 5));
  // Seed scrollback so a tail exists to (not) ship.
  host.ingestOutputForTest(
    'h:22:u:1',
    Uint8List.fromList('hello world\n'.codeUnits),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
  final col = _SnapshotCollector(pair.uiSide);
  return (pair: pair, host: host, col: col);
}

void main() {
  test(
    'B: periodic push is dirty-checked — an idle session emits nothing (#806)',
    () async {
      final s = await _setup();
      addTearDown(() async {
        await s.col.cancel();
        await s.host.dispose();
        await s.pair.dispose();
      });

      // Let several periodic ticks pass with NO change after the first.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      // At most one snapshot: the first periodic tick after connect ships the
      // initial state; subsequent unchanged ticks are skipped.
      expect(
        s.col.events.length,
        lessThanOrEqualTo(1),
        reason: 'unchanged session must not re-emit every tick',
      );
    },
  );

  test('B: a change re-arms the periodic push (#806)', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.col.cancel();
      await s.host.dispose();
      await s.pair.dispose();
    });

    await Future<void>.delayed(const Duration(milliseconds: 60));
    final before = s.col.events.length;
    // New remote bytes → metrics + scrollback change → next tick emits.
    s.host.ingestOutputForTest(
      'h:22:u:1',
      Uint8List.fromList('more output\n'.codeUnits),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      s.col.events.length,
      greaterThan(before),
      reason: 'a state/byte/scrollback change must produce a fresh snapshot',
    );
  });

  test(
    'C: PERIODIC payload omits scrollback; on-demand includes it (#806)',
    () async {
      final s = await _setup();
      addTearDown(() async {
        await s.col.cancel();
        await s.host.dispose();
        await s.pair.dispose();
      });

      // Force a change so a periodic snapshot ships, then read it.
      s.host.ingestOutputForTest(
        'h:22:u:1',
        Uint8List.fromList('tick\n'.codeUnits),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final periodic = s.col.events.last;
      expect(
        periodic.scrollbackTail,
        isEmpty,
        reason: 'periodic snapshot must NOT carry the ~4KB scrollback decode',
      );

      // On-demand request (audit live view / resume rebind) → full payload.
      s.pair.uiSide.send(
        const SshRequestSnapshotCommand(sessionId: 'h:22:u:1').toJson(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final onDemand = s.col.events.last;
      expect(
        onDemand.scrollbackTail,
        contains('hello world'),
        reason: 'on-demand snapshot must carry the scrollback tail',
      );
    },
  );

  test(
    'A: setActive(false) stops the periodic timer; (true) restores + emits one '
    'fresh snapshot immediately (#806)',
    () async {
      final s = await _setup();
      addTearDown(() async {
        await s.col.cancel();
        await s.host.dispose();
        await s.pair.dispose();
      });

      // Background: stop the timer.
      s.pair.uiSide.send(const SshSetActiveCommand(active: false).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Even a change while backgrounded must NOT produce a periodic snapshot.
      s.host.ingestOutputForTest(
        'h:22:u:1',
        Uint8List.fromList('bg output\n'.codeUnits),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final whilePaused = s.col.events.length;

      // Foreground: restore the timer AND emit one fresh full snapshot now.
      s.pair.uiSide.send(const SshSetActiveCommand(active: true).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        s.col.events.length,
        greaterThan(whilePaused),
        reason: 'resume must re-emit a fresh snapshot for instant repaint',
      );
      // The resume snapshot carries the scrollback (full payload for repaint).
      expect(s.col.events.last.scrollbackTail, contains('bg output'));

      // And the session stayed connected throughout (snapshots are UI-only):
      // the resume snapshot reports `connected`, proving the gate never touched
      // the SSH lifecycle.
      expect(s.col.events.last.state, SshSessionState.connected.name);
    },
  );

  test('A: no periodic snapshots accumulate while paused (#806)', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.col.cancel();
      await s.host.dispose();
      await s.pair.dispose();
    });

    s.pair.uiSide.send(const SshSetActiveCommand(active: false).toJson());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final baseline = s.col.events.length;
    // Drive many ticks worth of wall time + a change each — none should ship.
    for (var i = 0; i < 5; i++) {
      s.host.ingestOutputForTest(
        'h:22:u:1',
        Uint8List.fromList('paused $i\n'.codeUnits),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(
      s.col.events.length,
      baseline,
      reason: 'paused: the periodic timer is stopped, no snapshots emitted',
    );
  });
}
