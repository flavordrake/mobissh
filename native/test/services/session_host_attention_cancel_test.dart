// Session-death attention-notification cancel (#885).
//
// An attention notification must not outlive its session: when a session
// reaches a TERMINAL state (failed / disconnected — including the user closing
// it), the host cancels that HOST's attention notification (host-keyed tag,
// #847). TRANSIENT drop states (softDisconnected / reconnecting — the
// auto-reconnect path is still in flight) must NOT cancel: the session can
// revive and the notification can still deliver. A host with ANOTHER live
// session must NOT cancel either — the #857 host-fallback can still route the
// tap to that sibling.
//
// Headless via InMemoryGatewayPair + inert controllers the test drives directly
// (no real socket), with a RecordingAttentionNotifier so no platform channels.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_attention_notification.dart';
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

/// Inert controller: the test owns connected + the drop; a reconnect attempt
/// fail-fasts only when the test exhausts it deliberately.
class _NoConnectController extends SshSessionController {
  _NoConnectController({super.reconnectDelay});

  @override
  Future<void> connect(SshConnectParams params) async {}
}

class _Harness {
  _Harness(this.host, this.pair, this.notifier, this.controllers);
  final SessionHost host;
  final InMemoryGatewayPair pair;
  final RecordingAttentionNotifier notifier;

  /// Controllers in creation order (one per connect command).
  final List<SshSessionController> controllers;
}

Future<_Harness> _spawn() async {
  final controllers = <SshSessionController>[];
  final pair = InMemoryGatewayPair();
  final notifier = RecordingAttentionNotifier();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: () {
      // A LONG reconnect delay so a transient drop parks in `reconnecting`
      // instead of racing through exhausted attempts to `failed`.
      final c = _NoConnectController(reconnectDelay: const Duration(hours: 1));
      controllers.add(c);
      return c;
    },
    snapshotInterval: const Duration(hours: 1),
    attentionNotifier: notifier,
    replayWindow: Duration.zero,
  );
  return _Harness(host, pair, notifier, controllers);
}

Future<void> _connect(_Harness h, String sid, {String host = 'h'}) async {
  h.pair.uiSide.send(
    SshConnectCommand(
      sessionId: sid,
      host: host,
      port: 22,
      username: 'u',
      authJson: const {'type': 'password', 'password': 'p'},
    ).toJson(),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
  h.controllers.last.debugSetConnectedForTest(_params);
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

void main() {
  test('connected → failed (terminal) cancels the host notification', () async {
    const sid = 'h:22:u:1';
    final h = await _spawn();
    addTearDown(() async {
      await h.host.dispose();
      await h.pair.dispose();
    });
    await _connect(h, sid);
    expect(h.notifier.cancelled, isEmpty);

    // Non-transient transport error → `failed` directly (terminal).
    h.controllers.single.handleTransportClosed(StateError('fatal'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(h.notifier.cancelled, [sid],
        reason: 'a terminally-failed session must cancel its host notification');
  });

  test('user disconnect (SshDisconnectCommand) cancels the host notification',
      () async {
    const sid = 'h:22:u:2';
    final h = await _spawn();
    addTearDown(() async {
      await h.host.dispose();
      await h.pair.dispose();
    });
    await _connect(h, sid);

    h.pair.uiSide.send(SshDisconnectCommand(sessionId: sid).toJson());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(h.notifier.cancelled, [sid],
        reason: 'a user-closed session must cancel its host notification');
  });

  test(
    'TRANSIENT drop (softDisconnected → reconnecting) does NOT cancel',
    () async {
      const sid = 'h:22:u:3';
      final h = await _spawn();
      addTearDown(() async {
        await h.host.dispose();
        await h.pair.dispose();
      });
      await _connect(h, sid);

      // Clean transport close from `connected` → softDisconnected + an armed
      // reconnect (the 1h delay parks it in `reconnecting`).
      h.controllers.single.handleTransportClosed(null);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(h.controllers.single.data.state, SshSessionState.reconnecting,
          reason: 'precondition: the drop must park in the transient state');
      expect(h.notifier.cancelled, isEmpty,
          reason: 'a transient reconnecting drop can still revive — the '
              'notification must survive it');
    },
  );

  test(
    'sibling session to the SAME host still live → NO cancel until the last '
    'one dies',
    () async {
      const sidA = 'h:22:u:1';
      const sidB = 'h:2222:u:2';
      final h = await _spawn();
      addTearDown(() async {
        await h.host.dispose();
        await h.pair.dispose();
      });
      await _connect(h, sidA);
      await _connect(h, sidB);

      // Kill A terminally — B (same host `h`) is still connected, so the host
      // can still deliver the tap via the #857 host-fallback. No cancel.
      h.controllers[0].handleTransportClosed(StateError('fatal'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.notifier.cancelled, isEmpty,
          reason: 'host h still has a live session — keep the notification');

      // Now kill B too — the host is fully dead → cancel.
      h.controllers[1].handleTransportClosed(StateError('fatal'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.notifier.cancelled, [sidB],
          reason: 'the LAST live session dying must cancel the host slot');
    },
  );

  test('a DIFFERENT host dying does not cancel this host', () async {
    const sidH = 'h:22:u:1';
    const sidOther = 'other:22:u:1';
    final h = await _spawn();
    addTearDown(() async {
      await h.host.dispose();
      await h.pair.dispose();
    });
    await _connect(h, sidH, host: 'h');
    await _connect(h, sidOther, host: 'other');

    h.controllers[1].handleTransportClosed(StateError('fatal'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(h.notifier.cancelled, [sidOther],
        reason: 'only the dead host (`other`) is cancelled — host h keeps its '
            'notification slot');
  });

  test('host dispose (graceful FGS stop) cancels every hosted host', () async {
    const sidA = 'h:22:u:1';
    const sidB = 'other:22:u:1';
    final h = await _spawn();
    addTearDown(() async {
      await h.pair.dispose();
    });
    await _connect(h, sidA, host: 'h');
    await _connect(h, sidB, host: 'other');

    await h.host.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final cancelledHosts =
        h.notifier.cancelled.map(hostOfSessionId).toSet();
    expect(cancelledHosts, {'h', 'other'},
        reason: 'a graceful FGS stop kills every session — no notification can '
            'deliver, so every host slot is cancelled');
  });
}
