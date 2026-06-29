// SessionHost attention suppression when the front-most session is DISCONNECTED
// (#936). Telemetry (v0.1.10+70) showed a bell firing while the user was ALREADY
// on the session: the active session had DISCONNECTED, so the UI propagated
// activeSessionId=null / activeHost=null, and shouldPostAttention's
// `if (frontHost == null) return true` branch POSTED. These tests pin the fix:
//
//   1. Foreground + active session whose HOST is derivable from a non-null
//      activeSessionId (even if not "connected") + same-host bell → SUPPRESSED.
//   2. A TRANSIENT setActive carrying activeHost=null (disconnect blip) while
//      foregrounded must NOT clobber the last-known activeHost — a subsequent
//      same-host bell is still SUPPRESSED.
//
// Headless via InMemoryGatewayPair + an inert controller (mirrors
// session_host_attention_telemetry_test.dart) against a RecordingAttentionNotifier.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
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

class _NoConnectController extends SshSessionController {
  @override
  Future<void> connect(SshConnectParams params) async {}
}

Future<({InMemoryGatewayPair pair, SessionHost host, RecordingAttentionNotifier notifier})>
_setup({String sid = 'h:22:u:1'}) async {
  late SshSessionController controller;
  final pair = InMemoryGatewayPair();
  final notifier = RecordingAttentionNotifier();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: () {
      controller = _NoConnectController();
      return controller;
    },
    snapshotInterval: const Duration(milliseconds: 50),
    attentionNotifier: notifier,
    // Disable both upstream gates so these tests exercise only the
    // foreground/host suppression they assert on (see telemetry test rationale).
    replayWindow: Duration.zero,
    switchGraceWindow: Duration.zero,
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
  controller.debugSetConnectedForTest(_params);
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return (pair: pair, host: host, notifier: notifier);
}

/// OSC 9 bytes carrying [text].
List<int> _osc9(String text) => [0x1b, 0x5d, ...utf8.encode('9;$text'), 0x07];

void main() {
  setUp(clearConnectLog);

  test(
      'foreground + disconnected active session (host derivable) + same-host '
      'bell → SUPPRESSED', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // The user is foregrounded on the front-most session tab whose underlying
    // SSH has DISCONNECTED. The UI no longer resolves a CONNECTED entry, but the
    // front-most tab's id (and therefore its HOST) is still known and propagated.
    // Crucially activeHost is omitted (null) — exactly the #936 device case — so
    // suppression must fall back to deriving the host from activeSessionId.
    s.pair.uiSide.send(
      const SshSetActiveCommand(
        active: true,
        activeSessionId: 'h:22:u:1',
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(s.notifier.posted, isEmpty,
        reason: 'user is on this very (disconnected) session — must suppress');
  });

  test(
      'transient activeHost=null setActive must NOT clobber last-known host — '
      'same-host bell still SUPPRESSED', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // 1. Foreground on the session to host 'h' — last-known activeHost='h'.
    s.pair.uiSide.send(
      const SshSetActiveCommand(
        active: true,
        activeSessionId: 'h:22:u:1',
        activeHost: 'h',
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // 2. A transient disconnect blip pushes a setActive with BOTH id and host
    //    null while STILL foregrounded. This must NOT erase the last-known host.
    s.pair.uiSide.send(
      const SshSetActiveCommand(active: true).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // 3. A same-host bell arrives during the blip. The user is still looking at
    //    host 'h', so it must be suppressed against the retained last-known host.
    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(s.notifier.posted, isEmpty,
        reason:
            'a transient null setActive must retain last-known activeHost so a '
            'same-host bell during a disconnect blip still suppresses');
  });
}
