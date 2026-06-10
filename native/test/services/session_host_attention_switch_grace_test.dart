// SessionHost attention JUST-SWITCHED grace window (#856).
//
// Switching TO a session flushes its catch-up output; a bell in that burst would
// otherwise post a redundant attention notification for the session the user just
// switched to (foreground + now-active). The #847 host-suppression keys on
// `activeHost`, but there is a RACE: the catch-up output is scanned by the task
// isolate BEFORE the `setActive(newHost)` command lands, so the suppression check
// still sees the OLD active host → posts. #851's replay window only re-arms on a
// CONNECT transition, not on a session SWITCH, so it doesn't cover this.
//
// Fix: when `setActive` CHANGES the active host, arm a short "just-switched" grace
// window for the newly-active HOST. A signal for that host within the window is
// suppressed (logged `suppressed (just-switched …)`) but not posted; after the
// window, posts normally. Additive to + composes with #847 + #851.
//
// The window is gated on the host's injected clock (`nowMs`) and an injected
// `switchGraceWindow`, so it is deterministic without wall-clock sleeps.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

/// A controller whose `connect` is inert so the TEST owns every state
/// transition (it drives `connected` via [debugSetConnectedForTest]).
class _NoConnectController extends SshSessionController {
  @override
  Future<void> connect(SshConnectParams params) async {}
}

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

/// Bare BEL — a text-less bell, the generic attention signal.
List<int> _bell() => [0x07];

void main() {
  // Mutable injected clock (ms). Tests advance `now` to cross the grace window
  // without any real-time sleep.
  late int now;
  late InMemoryGatewayPair pair;
  late SessionHost host;
  late RecordingAttentionNotifier notifier;
  // sessionId → its controller, captured at connect time so tests can drive
  // `connected` (to arm the #851 replay window).
  late Map<String, SshSessionController> controllers;
  // The session id of the in-flight connect, so the factory (called once per
  // connect, in order) can bind the new controller to it.
  String? pendingSid;

  // Session H on host `h`; session G on a DIFFERENT host `g`.
  const sidH = 'h:22:u:1';
  const sidG = 'g:22:u:2';
  const grace = Duration(milliseconds: 1500);
  // A long replay window OFF for the grace-specific tests (so the replay gate
  // doesn't mask whether the grace gate is doing the work). The compose-with-#851
  // test re-enables it.
  const noReplay = Duration.zero;

  Future<void> setUpHost({Duration replay = noReplay}) async {
    now = 1000;
    controllers = {};
    pair = InMemoryGatewayPair();
    notifier = RecordingAttentionNotifier();
    pendingSid = null;
    // The factory is called once per connect, in connect order. We bind each new
    // controller to the most-recently-requested session id (set in connectSession
    // right before sending the connect command).
    host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: () {
        final c = _NoConnectController();
        final sid = pendingSid;
        if (sid != null) controllers[sid] = c;
        return c;
      },
      snapshotInterval: const Duration(milliseconds: 50),
      attentionNotifier: notifier,
      nowMs: () => now,
      replayWindow: replay,
      switchGraceWindow: grace,
    );
  }

  Future<void> connectSession(String sid, String host_) async {
    pendingSid = sid;
    pair.uiSide.send(
      SshConnectCommand(
        sessionId: sid,
        host: host_,
        port: 22,
        username: 'u',
        authJson: const {'type': 'password', 'password': 'p'},
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  /// Drive [sid]'s controller to `connected` so the #851 replay window arms.
  Future<void> reachConnected(String sid) async {
    controllers[sid]!.debugSetConnectedForTest(_params);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  void setActive(String activeSessionId, String activeHost) {
    pair.uiSide.send(
      SshSetActiveCommand(
        active: true,
        activeSessionId: activeSessionId,
        activeHost: activeHost,
      ).toJson(),
    );
  }

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  Future<void> tearDownHost() async {
    await host.dispose();
    await pair.dispose();
  }

  test('bell for host H WITHIN the just-switched grace window after '
      'setActive(H) is NOT posted', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await connectSession(sidH, 'h');
    // Switch TO host H (active-host change null→h arms the grace at now=1000).
    setActive(sidH, 'h');
    await pump();

    now += 500; // 0.5s into the 1.5s grace → catch-up burst
    host.feedAttentionForTest(sidH, _bell());
    await pump();

    expect(notifier.posted, isEmpty,
        reason: 'a bell in the switch catch-up burst is redundant');
  });

  test('the SAME bell AFTER the grace window posts (live output)', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await connectSession(sidH, 'h');
    await connectSession(sidG, 'g');
    setActive(sidH, 'h'); // grace armed for h at now=1000
    await pump();
    // Move foreground to a DIFFERENT host so #847 foreground-suppression does NOT
    // apply to h — we want to verify the GRACE alone, not host-suppression.
    setActive(sidG, 'g');
    await pump();

    now += 1600; // past h's 1.5s grace → live
    host.feedAttentionForTest(sidH, _bell());
    await pump();

    expect(notifier.posted, hasLength(1),
        reason: 'after the grace settles, live attention posts normally');
  });

  test('setActive to a DIFFERENT host does NOT grace-suppress H', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await connectSession(sidH, 'h');
    await connectSession(sidG, 'g');
    // Switch to host G — only G is graced; H is NOT in the foreground.
    setActive(sidG, 'g');
    await pump();

    now += 500; // inside G's grace, but the bell is from H
    host.feedAttentionForTest(sidH, _bell());
    await pump();

    expect(notifier.posted, hasLength(1),
        reason: 'graceing the newly-active host G must not suppress host H');
  });

  test('grace composes with #847: foregrounded same-host stays suppressed '
      'AFTER the grace window', () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await connectSession(sidH, 'h');
    setActive(sidH, 'h'); // grace armed; foreground on host h (#847 applies)
    await pump();

    // Inside the grace → suppressed (just-switched).
    now += 200;
    host.feedAttentionForTest(sidH, _bell());
    await pump();
    expect(notifier.posted, isEmpty);

    // Outside the grace, but STILL foregrounded same-host → #847 suppresses.
    now += 2000;
    host.feedAttentionForTest(sidH, _bell());
    await pump();
    expect(notifier.posted, isEmpty,
        reason: 'host-suppression holds independently of the grace gate');
  });

  test('grace composes with #851: post-connect replay still suppresses', () async {
    // Replay window ON (1.5s). A bell right after connect is replay-suppressed
    // even with no switch — the gates stack, neither removes the other.
    await setUpHost(replay: const Duration(milliseconds: 1500));
    addTearDown(tearDownHost);
    await connectSession(sidH, 'h');
    await reachConnected(sidH); // replay window armed at now=1000
    // No setActive → grace NOT armed; the #851 replay gate must do the work.
    now += 400; // inside the replay window
    host.feedAttentionForTest(sidH, _bell());
    await pump();
    expect(notifier.posted, isEmpty,
        reason: 'the #851 replay gate is unaffected by the grace gate');
  });

  test('re-asserting the SAME active host does NOT extend the grace window',
      () async {
    await setUpHost();
    addTearDown(tearDownHost);
    await connectSession(sidH, 'h');
    await connectSession(sidG, 'g');
    setActive(sidH, 'h'); // grace armed for h at now=1000, expires at 2500
    await pump();

    // Re-assert the SAME active host repeatedly as time advances. If re-assert
    // re-armed the grace, the window would never close.
    now += 1000; // 2000
    setActive(sidH, 'h');
    await pump();
    now += 1000; // 3000 — past the ORIGINAL 1500ms window from now=1000
    setActive(sidH, 'h');
    await pump();

    // Move foreground OFF host h so #847 doesn't mask the grace check. h's grace
    // (armed at 1000) must already be expired and NOT re-armed by the re-asserts.
    setActive(sidG, 'g');
    await pump();

    host.feedAttentionForTest(sidH, _bell());
    await pump();
    expect(notifier.posted, hasLength(1),
        reason: 're-asserting the same active host must not re-arm the grace');
  });

  test('default switch-grace window is the tunable const (~1.5s)', () {
    expect(kAttentionSwitchGraceWindow, const Duration(milliseconds: 1500));
  });
}
