// SessionHost attention DECISION-INPUT telemetry (#840 follow-up).
//
// The attention gate previously logged WHY it SUPPRESSED but, on a POST, logged
// only the outcome ("posted notification session …") — never the decision
// inputs. So a device capture of "a bell fired while the app was foreground"
// could not reveal whether the task isolate believed the app was foreground and
// what activeHost it had. These tests pin the new telemetry:
//   1. On a POST the lifecycle ring carries foreground/activeSessionId/
//      activeHost/signalHost + reason.
//   2. On a same-host SUPPRESS the same inputs are logged.
//   3. Every setActive the task isolate APPLIES is logged (UI→task propagation).
//
// Headless via InMemoryGatewayPair + an inert controller (mirrors
// session_host_attention_post_test.dart) against a RecordingAttentionNotifier.

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
    // Disable the (re)connect replay window AND the #856 just-switched grace so
    // these tests exercise only the foreground/host gate they assert on (both
    // upstream gates have their own coverage). Without disabling the grace, a
    // setActive(activeHost:'h') arms the just-switched window and suppresses via
    // THAT path before the same-host foreground gate is reached.
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

  test('POST logs the full decision inputs (foreground/active/signalHost)',
      () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // App backgrounded → posts. The default activeHost is null (never set).
    s.pair.uiSide.send(
      const SshSetActiveCommand(active: false).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    s.host.feedAttentionForTest('h:22:u:1', _osc9('ready'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(s.notifier.posted, hasLength(1));
    final lines = lifecycleLogSnapshot();
    final postLine = lines.firstWhere(
      (l) => l.contains('posted notification session h:22:u:1'),
      orElse: () => '',
    );
    expect(postLine, isNotEmpty,
        reason: 'a POST must emit a lifecycle line');
    expect(postLine, contains('foreground=false'));
    expect(postLine, contains('activeSessionId=null'));
    expect(postLine, contains('activeHost=null'));
    expect(postLine, contains('signalHost=h'));
    expect(postLine, contains('reason=not-suppressed'));
  });

  test('same-host SUPPRESS logs the full decision inputs', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    // Foreground on a DIFFERENT session to the SAME host → suppressed.
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

    expect(s.notifier.posted, isEmpty);
    final lines = lifecycleLogSnapshot();
    final suppressLine = lines.firstWhere(
      (l) => l.contains('suppressed (foreground same-host) session h:22:u:1'),
      orElse: () => '',
    );
    expect(suppressLine, isNotEmpty);
    expect(suppressLine, contains('foreground=true'));
    expect(suppressLine, contains('activeSessionId=h:2222:u:2'));
    expect(suppressLine, contains('activeHost=h'));
    expect(suppressLine, contains('signalHost=h'));
  });

  test('task isolate logs every setActive it APPLIES', () async {
    final s = await _setup();
    addTearDown(() async {
      await s.host.dispose();
      await s.pair.dispose();
    });
    s.pair.uiSide.send(
      const SshSetActiveCommand(
        active: true,
        activeSessionId: 'h:22:u:1',
        activeHost: 'h',
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final lines = lifecycleLogSnapshot();
    final applyLine = lines.firstWhere(
      (l) => l.contains('setActive active=true'),
      orElse: () => '',
    );
    expect(applyLine, isNotEmpty,
        reason: 'the task isolate must log the applied setActive');
    expect(applyLine, contains('activeSessionId=h:22:u:1'));
    expect(applyLine, contains('host=h'));
  });
}
