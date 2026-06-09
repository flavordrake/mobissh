// SessionHost attention NOTIFICATION posting + suppression (#840, Slice 2).
//
// At the Slice-1 detection point the host now posts an attention notification
// (per-session tag) UNLESS the signalling session is the active one AND the app
// is foregrounded. This drives that path through the test seam
// `feedAttentionForTest` (mirrors the live PTY listener) against a recording
// notifier — no platform channels.
//
// Headless via InMemoryGatewayPair + an inert controller so the test owns the
// `connected` transition.

import 'dart:convert';

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
  test('OSC9 detection posts an attention notification for that session', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // Foreground but NO active session set yet → not suppressed → posts.
    s.host.feedAttentionForTest('h:22:u:1', _osc9('Claude — main (win 3)'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(s.notifier.posted, hasLength(1));
    final n = s.notifier.posted.single;
    // #847: tag is now per-HOST (host `h`), not per-session.
    expect(n.tag, 'mobissh.attention.h');
    expect(n.body, 'Claude — main');
    expect(n.sourceWindow, 3);
    final payload = jsonDecode(n.payload) as Map;
    // Payload still routes the tap to the EXACT session.
    expect(payload['sessionId'], 'h:22:u:1');
  });

  test('#847 SUPPRESSED when foregrounded on a DIFFERENT session to the SAME '
      'host', () async {
    // Signalling session is h:22:u:1 (host h). The user is foregrounded on a
    // DIFFERENT session to the SAME host (h:2222:u:2) — the unit of attention is
    // the host, so the bell is suppressed.
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    s.pair.uiSide.send(
      const SshSetActiveCommand(
        active: true,
        activeSessionId: 'h:2222:u:2',
        activeHost: 'h',
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.notifier.posted, isEmpty,
        reason: 'foregrounded on the same host (different session) → suppress');
  });

  test('SUPPRESSED when session is active AND app foregrounded', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // UI reports foreground + this session active.
    s.pair.uiSide.send(
      const SshSetActiveCommand(active: true, activeSessionId: 'h:22:u:1')
          .toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.notifier.posted, isEmpty,
        reason: 'active + foreground session must not notify');
  });

  test('POSTS when backgrounded even if this session is active', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    s.pair.uiSide.send(
      const SshSetActiveCommand(active: false, activeSessionId: 'h:22:u:1')
          .toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.notifier.posted, hasLength(1));
  });

  test('POSTS for a NON-active session while foregrounded', () async {
    final s = await _setup(sid: 'h:22:u:1');
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // Foreground, but a DIFFERENT session is active.
    s.pair.uiSide.send(
      const SshSetActiveCommand(active: true, activeSessionId: 'other')
          .toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.notifier.posted, hasLength(1));
  });
}
