// SessionHost attention REPLAY-WINDOW suppression (#851).
//
// A bell that arrives within the post-`connected` (re)connect scrollback-REPLAY
// / catch-up window is HISTORICAL — replayed when the session re-attaches (tmux
// re-attach, shell re-init, buffered scrollback) — not a genuinely live "Claude
// needs you now" moment. The owner: "notifications shouldn't bubble up the
// second I reconnect." So the host suppresses attention POSTS for a short,
// tunable cooldown (`kAttentionReplayWindow`) after EVERY connected transition
// (initial connect AND reconnect/softDisconnected→connected), re-arming the
// window on each one. After the window, live signals post normally.
//
// This is an ADDITIONAL gate composing with the #847 host-suppression + dedup —
// it does not replace them.
//
// The window is gated on the host's injected clock (`nowMs`) and an injected
// `replayWindow`, so it is deterministic without wall-clock sleeps.

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

/// A controller whose `connect` is inert so the TEST owns every state
/// transition (it drives `connected` via [debugSetConnectedForTest] and drops
/// via [handleTransportClosed]).
class _NoConnectController extends SshSessionController {
  @override
  Future<void> connect(SshConnectParams params) async {}
}

/// Bare BEL — a text-less bell, exactly the generic signal #851 calls out.
List<int> _bell() => [0x07];

void main() {
  // Mutable injected clock (ms). Tests advance `now` to cross the replay window
  // without any real-time sleep.
  late int now;
  late InMemoryGatewayPair pair;
  late SessionHost host;
  late RecordingAttentionNotifier notifier;
  late SshSessionController controller;
  const sid = 'h:22:u:1';
  const replay = Duration(milliseconds: 1500);

  Future<void> setUpHost() async {
    now = 1000;
    pair = InMemoryGatewayPair();
    notifier = RecordingAttentionNotifier();
    host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: () {
        controller = _NoConnectController();
        return controller;
      },
      snapshotInterval: const Duration(milliseconds: 50),
      attentionNotifier: notifier,
      nowMs: () => now,
      replayWindow: replay,
    );
    pair.uiSide.send(
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

  /// Drive the controller to `connected` (re)stamping the host's window.
  Future<void> reachConnected() async {
    controller.debugSetConnectedForTest(_params);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  Future<void> tearDownHost() async {
    await host.dispose();
    await pair.dispose();
  }

  test('bell WITHIN the post-connect replay window is NOT posted '
      '(suppressed as replay)', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await reachConnected(); // window armed at now=1000

    now += 500; // 0.5s into the 1.5s window → replay
    host.feedAttentionForTest(sid, _bell());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(notifier.posted, isEmpty,
        reason: 'a bell inside the (re)connect replay window is historical');
  });

  test('the SAME bell AFTER the window posts (live output)', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await reachConnected(); // armed at now=1000

    now += 1600; // past the 1.5s window → live
    host.feedAttentionForTest(sid, _bell());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(notifier.posted, hasLength(1),
        reason: 'after the window settles, live attention posts normally');
  });

  test('reconnect (softDisconnected→connected) RE-ARMS the window', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await reachConnected(); // armed at now=1000

    // Move well past the first window so we are firmly in "live" territory.
    now += 5000;
    // Drop the transport cleanly: connected → softDisconnected (→ reconnect).
    controller.handleTransportClosed(null);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // Reconnect lands back on `connected` LATER — this re-stamps the window.
    now += 1000;
    await reachConnected(); // window RE-armed at the new `now`

    // A bell immediately after the reconnect is replayed scrollback → suppress.
    now += 400; // inside the re-armed 1.5s window
    host.feedAttentionForTest(sid, _bell());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(notifier.posted, isEmpty,
        reason: 'each reconnect re-suppresses its own replay burst');
  });

  test('live attention LONG after connect still posts', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await reachConnected(); // armed at now=1000

    now += 60000; // a full minute later — unmistakably live
    host.feedAttentionForTest(sid, _bell());
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(notifier.posted, hasLength(1));
  });

  test('composes with #847 host-suppression: foregrounded same-host is '
      'suppressed REGARDLESS of the replay window', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await reachConnected();
    // Foreground on the SAME host (#847 host-suppression applies).
    pair.uiSide.send(
      const SshSetActiveCommand(
        active: true,
        activeSessionId: sid,
        activeHost: 'h',
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Inside the window → suppressed (replay).
    now += 200;
    host.feedAttentionForTest(sid, _bell());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifier.posted, isEmpty);

    // Outside the window, but STILL foregrounded same-host → #847 suppresses.
    now += 2000;
    host.feedAttentionForTest(sid, _bell());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifier.posted, isEmpty,
        reason: 'host-suppression holds independently of the replay gate');
  });

  test('default replay window is the tunable const (~1.5s)', () {
    expect(kAttentionReplayWindow, const Duration(milliseconds: 1500));
  });
}
