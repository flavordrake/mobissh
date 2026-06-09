// Liveness-heartbeat instrumentation (#838).
//
// A SILENT mid-session drop fires NO transition — the session sits `connected`
// over a dead link and #836's transition log shows nothing. The heartbeat
// closes that observability gap: while `connected`, the host emits a periodic
// `heartbeat: alive ... lastActivityAgeMs=N` line (piggybacked on the existing
// snapshot tick, NO new timer). A silent drop is then visible as "heartbeat
// keeps saying alive but lastActivityAgeMs keeps growing" — the undetected-drop
// window #766 will close.
//
// Headless via InMemoryGatewayPair + an injectable clock so the age is
// deterministic, and a short snapshot interval so the piggybacked tick fires.

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

class _NoConnectController extends SshSessionController {
  _NoConnectController() : super(reconnectDelay: Duration.zero);
  @override
  Future<void> connect(SshConnectParams params) async {}
}

void main() {
  setUp(clearConnectLog);
  tearDown(() {
    lifecycleForwarder = null;
    clearConnectLog();
  });

  test(
    'a connected session emits heartbeats with a GROWING lastActivityAge while '
    'NO transition fires (silent-drop visibility)',
    () async {
      const sid = 'h:22:u:1';
      final clock = <int>[0];
      late SshSessionController controller;
      SshSessionController factory() => controller = _NoConnectController();

      final pair = InMemoryGatewayPair();
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: factory,
        // Short tick so the piggybacked heartbeat fires quickly in the test.
        snapshotInterval: const Duration(milliseconds: 20),
        nowMs: () => clock.first,
      );
      addTearDown(() async {
        await host.dispose();
        await pair.dispose();
      });

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

      // Connected at t=0 with a fresh byte at t=0.
      clock[0] = 0;
      controller.debugSetConnectedForTest(_params);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      host.ingestOutputForTest(sid, Uint8List.fromList([1]));

      // Advance the clock past the heartbeat interval and let the snapshot tick
      // fire twice — at t=10000 and t=25000. No byte ingested, no transition:
      // the link is silently dead. Heartbeats must still fire, age growing.
      clock[0] = 10000;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      clock[0] = 25000;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final beats = lifecycleLogSnapshot()
          .where((l) => l.contains('heartbeat:'))
          .toList();
      expect(
        beats.length,
        greaterThanOrEqualTo(2),
        reason: 'heartbeat must keep firing while connected. Got: $beats',
      );
      for (final b in beats) {
        expect(b, contains('alive state=connected'));
      }
      // Age must be strictly growing across the two beats (silent drop signal).
      int ageOf(String l) =>
          int.parse(RegExp(r'lastActivityAgeMs=(\d+)').firstMatch(l)!.group(1)!);
      final ages = beats.map(ageOf).toList();
      expect(
        ages.last,
        greaterThan(ages.first),
        reason: 'lastActivityAgeMs must grow under a silent drop. $ages',
      );
    },
  );

  test(
    'no heartbeat fires for a session that is NOT connected',
    () async {
      const sid = 'h:22:u:2';
      final clock = <int>[0];
      SshSessionController factory() => _NoConnectController();

      final pair = InMemoryGatewayPair();
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: factory,
        snapshotInterval: const Duration(milliseconds: 20),
        nowMs: () => clock.first,
      );
      addTearDown(() async {
        await host.dispose();
        await pair.dispose();
      });

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
      // Stays idle (no debugSetConnectedForTest). Advance time + tick.
      clock[0] = 30000;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        lifecycleLogSnapshot().where((l) => l.contains('heartbeat:')),
        isEmpty,
        reason: 'only connected sessions get a heartbeat',
      );
    },
  );
}
