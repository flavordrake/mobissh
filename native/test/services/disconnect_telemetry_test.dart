// Disconnect-case instrumentation (#838).
//
// Builds on #836's state-transition logging. For each disconnect CAUSE this
// asserts the host writes ONE structured `disconnect:` line to the durable
// lifecycle ring carrying: cause label, prev→new edge, end-time→detection
// LATENCY, transport/keepalive/attempt/intent context, and a monotonic edge#.
// The edge# is the "cut once" guard — a flap shows as increasing edges, a true
// double-fire would show two lines with the same prev→new at one instant.
//
// Headless via InMemoryGatewayPair + a no-connect controller the test drives
// directly (no real socket), and an injectable clock so latency is deterministic.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
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

/// Inert controller: the test owns connected + the drop, the reconnect attempt
/// fail-fasts so the session settles instead of looping.
class _NoConnectController extends SshSessionController {
  _NoConnectController({super.reconnectDelay, super.reconnectAttemptOverride});

  @override
  Future<void> connect(SshConnectParams params) async {}
}

class _Harness {
  _Harness(this.host, this.pair, this.controllerOf, this.clock);
  final SessionHost host;
  final InMemoryGatewayPair pair;
  final SshSessionController Function() controllerOf;
  final List<int> clock;
}

Future<_Harness> _spawn({Duration reconnectDelay = Duration.zero}) async {
  late SshSessionController controller;
  final clock = <int>[1000]; // mutable "now"
  SshSessionController factory() {
    controller = _NoConnectController(
      reconnectDelay: reconnectDelay,
      reconnectAttemptOverride: (_) async => false,
    );
    return controller;
  }

  final pair = InMemoryGatewayPair();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: factory,
    snapshotInterval: const Duration(hours: 1),
    nowMs: () => clock.first,
  );
  return _Harness(host, pair, () => controller, clock);
}

Future<void> _connect(_Harness h, String sid) async {
  h.pair.uiSide.send(
    SshConnectCommand(
      sessionId: sid,
      host: 'h',
      port: 22,
      username: 'u',
      authJson: const {'type': 'password', 'password': 'p'},
    ).toJson(),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

void main() {
  setUp(clearConnectLog);
  tearDown(() {
    lifecycleForwarder = null;
    clearConnectLog();
  });

  test(
    'a clean server close (connected→softDisconnected) logs ONE disconnect line '
    'with cause + latency + a single edge',
    () async {
      const sid = 'h:22:u:1';
      final h = await _spawn();
      addTearDown(() async {
        await h.host.dispose();
        await h.pair.dispose();
      });
      await _connect(h, sid);

      // Reach connected at t=1000, last remote byte at t=2000.
      h.clock[0] = 1000;
      h.controllerOf().debugSetConnectedForTest(_params);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      h.clock[0] = 2000;
      h.host.ingestOutputForTest(sid, Uint8List.fromList([1, 2, 3]));

      // Detect the drop at t=5000 → latency = 5000 - 2000 = 3000ms.
      h.clock[0] = 5000;
      h.controllerOf().handleTransportClosed(null);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final lines = lifecycleLogSnapshot()
          .where((l) => l.contains('disconnect:'))
          .toList();
      expect(
        lines.length,
        1,
        reason: 'exactly ONE disconnect line per drop edge (cut once). '
            'Got: $lines',
      );
      final line = lines.single;
      expect(line, contains('cause=server-or-stale'));
      expect(line, contains('connected→softDisconnected'));
      expect(line, contains('latencyMs=3000'));
      expect(line, contains('from=lastByte'));
      expect(line, contains('edge=1'));
    },
  );

  test(
    'a user disconnect logs cause=user-disconnect intent=user',
    () async {
      const sid = 'h:22:u:2';
      final h = await _spawn();
      addTearDown(() async {
        await h.host.dispose();
        await h.pair.dispose();
      });
      await _connect(h, sid);
      h.controllerOf().debugSetConnectedForTest(_params);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      await h.controllerOf().disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final lines = lifecycleLogSnapshot()
          .where((l) => l.contains('disconnect:'))
          .toList();
      expect(lines.length, 1, reason: 'one drop edge. Got: $lines');
      expect(lines.single, contains('cause=user-disconnect'));
      expect(lines.single, contains('intent=user'));
      expect(lines.single, contains('→disconnected'));
    },
  );

  test(
    'latency falls back to connect time (from=connect) when no remote byte '
    'ever arrived',
    () async {
      const sid = 'h:22:u:3';
      final h = await _spawn();
      addTearDown(() async {
        await h.host.dispose();
        await h.pair.dispose();
      });
      await _connect(h, sid);
      h.clock[0] = 1000;
      h.controllerOf().debugSetConnectedForTest(_params);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // No ingestOutputForTest → never produced a byte.
      h.clock[0] = 4000;
      h.controllerOf().handleTransportClosed(null);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final line = lifecycleLogSnapshot()
          .firstWhere((l) => l.contains('disconnect:'));
      expect(line, contains('from=connect'));
      expect(line, contains('latencyMs=3000'));
    },
  );

  test(
    'a drop chain (softDisconnected → failed) logs each edge once with '
    'increasing edge# (no double-fire)',
    () async {
      const sid = 'h:22:u:4';
      // reconnect override returns false so the session exhausts and goes failed.
      final h = await _spawn();
      addTearDown(() async {
        await h.host.dispose();
        await h.pair.dispose();
      });
      await _connect(h, sid);
      h.controllerOf().debugSetConnectedForTest(_params);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      h.controllerOf().handleTransportClosed(null);
      // Drain reconnect microtasks until it settles on failed.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(Duration.zero);
        if (h.controllerOf().data.state == SshSessionState.failed) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final lines = lifecycleLogSnapshot()
          .where((l) => l.contains('disconnect:'))
          .toList();
      // First edge: connected→softDisconnected (edge=1). The chain may also
      // produce a reconnecting and/or failed edge; each must be unique + once.
      expect(lines.first, contains('edge=1'));
      final edges = lines
          .map((l) => RegExp(r'edge=(\d+)').firstMatch(l)!.group(1))
          .toList();
      expect(
        edges.toSet().length,
        edges.length,
        reason: 'every disconnect edge# is unique — no double-fire. $lines',
      );
    },
  );
}
