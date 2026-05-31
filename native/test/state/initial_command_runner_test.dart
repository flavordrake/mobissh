// Unit tests for the run-on-connect "initial command" once-only fire (#558).
//
// The runner arms a one-shot listener on a session's [SshSessionProxy]. On the
// FIRST `connected` transition it sends `command + "\n"` through the proxy's
// PTY input path (`sendInput`). It must NOT re-fire when the #551 reconnect
// work rebinds and re-emits `connected` on a background→resume.
//
// We drive a REAL proxy via an [InMemoryGatewayPair]: state events injected
// from the task side flip the proxy to `connected`; input commands the proxy
// sends are observed back on the task side, so we assert on the exact wire
// bytes (`base64(utf8(cmd + "\n"))`).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/sessions.dart';

void main() {
  group('InitialCommandRunner', () {
    late InMemoryGatewayPair pair;
    late SshSessionProxy proxy;
    const sid = 'h:22:u:1';

    // Input commands the proxy emitted, decoded back to their UTF-8 string.
    late List<String> sentInputs;
    late StreamSubscription<Map<String, dynamic>> taskSub;

    setUp(() {
      pair = InMemoryGatewayPair();
      proxy = SshSessionProxy(sessionId: sid, gateway: pair.uiSide);
      sentInputs = [];
      taskSub = pair.taskSide.incoming.listen((payload) {
        if (payload['kind'] == SshTaskCommandKind.input.name &&
            payload['sessionId'] == sid) {
          final bytes = base64Decode(payload['bytes'] as String);
          sentInputs.add(utf8.decode(bytes));
        }
      });
    });

    tearDown(() async {
      await taskSub.cancel();
      await proxy.dispose();
      await pair.dispose();
    });

    // Push a state event from the task side and let the proxy's broadcast
    // stream deliver it to the runner's listener.
    Future<void> emitState(SshSessionState state) async {
      pair.taskSide.send(
        SshStateEvent(sessionId: sid, state: state.name).toJson(),
      );
      // Let the gateway + proxy stream microtasks settle.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    test('sends command + newline once on first connected', () async {
      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      runner.arm(sessionId: sid, proxy: proxy, command: 'tmux attach');

      await emitState(SshSessionState.connecting);
      expect(sentInputs, isEmpty, reason: 'not fired before connected');

      await emitState(SshSessionState.connected);
      expect(sentInputs, ['tmux attach\n']);
      expect(runner.hasFired(sid), isTrue);
    });

    test(
      'does NOT re-fire on a second connected (reconnect rebind #551)',
      () async {
        final runner = InitialCommandRunner();
        addTearDown(runner.dispose);
        runner.arm(sessionId: sid, proxy: proxy, command: 'echo hi');

        await emitState(SshSessionState.connected);
        expect(sentInputs, ['echo hi\n']);

        // Simulate background→resume: soft-disconnect, reconnect, re-emit.
        await emitState(SshSessionState.softDisconnected);
        await emitState(SshSessionState.reconnecting);
        await emitState(SshSessionState.connected);

        expect(sentInputs, [
          'echo hi\n',
        ], reason: 'initial command must fire exactly once per session');
      },
    );

    test('empty / whitespace command is a no-op', () async {
      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      runner.arm(sessionId: sid, proxy: proxy, command: '   ');
      runner.arm(sessionId: sid, proxy: proxy, command: null);

      await emitState(SshSessionState.connected);
      expect(sentInputs, isEmpty);
      expect(runner.hasFired(sid), isFalse);
    });

    test('trims surrounding whitespace before sending', () async {
      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      runner.arm(sessionId: sid, proxy: proxy, command: '  ls -la  ');

      await emitState(SshSessionState.connected);
      expect(sentInputs, ['ls -la\n']);
    });

    test('does not fire when armed on an already-connected proxy', () async {
      // A dedup re-activate of a live session: proxy is already connected at
      // arm time. The command belongs to a fresh connect only.
      await emitState(SshSessionState.connected);

      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      runner.arm(sessionId: sid, proxy: proxy, command: 'whoami');

      await emitState(SshSessionState.connected);
      expect(sentInputs, isEmpty);
    });
  });
}
