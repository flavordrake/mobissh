// Issue #624: when a session is NOT `connected`, terminal-generated output
// (keystrokes AND the mouse-wheel SGR from WheelFixMouseHandler #617) must NOT
// be forwarded to the PTY. Otherwise scroll gestures on a dead session dump
// raw `64;x;yM` SGR bodies into the (re-opened plain) shell as literal text.
//
// These tests drive the per-session proxy state through the InMemoryGatewayPair
// (task side emits a state event) and assert what reaches the task side when
// the terminal emits output via its `onOutput` callback — the same callback
// SessionsNotifier wires to forward bytes to the PTY.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';

SshConnectParams _params() => const SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

/// Push a state transition to the UI proxy by emitting a task→UI state event.
void _emitState(InMemoryGatewayPair pair, String sessionId, String state) {
  pair.taskSide.send(
    SshStateEvent(sessionId: sessionId, state: state).toJson(),
  );
}

void main() {
  group('disconnected input gating (#624)', () {
    test('terminal output is NOT forwarded to the PTY when the session is '
        'disconnected', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(container.dispose);

      // Capture every input command that reaches the task side.
      final inputs = <SshInputCommand>[];
      final sub = pair.taskSide.incoming.listen((payload) {
        try {
          final cmd = SshTaskCommand.fromJson(payload);
          if (cmd is SshInputCommand) inputs.add(cmd);
        } catch (_) {}
      });
      addTearDown(sub.cancel);

      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(_params());

      // Drive the proxy to `disconnected`.
      _emitState(pair, entry.id, SshSessionState.disconnected.name);
      await Future<void>.delayed(Duration.zero);
      expect(entry.proxy.data.state, SshSessionState.disconnected);

      // A scroll gesture in tmux mouse-mode produces this SGR body via the
      // WheelFixMouseHandler; xterm surfaces it through Terminal.onOutput.
      entry.terminal.onOutput?.call('\x1b[<64;12;19M');
      await Future<void>.delayed(Duration.zero);

      expect(
        inputs,
        isEmpty,
        reason: 'no PTY input may be sent while not connected (#624)',
      );
    });

    test(
      'terminal output IS forwarded when the session is connected',
      () async {
        final pair = InMemoryGatewayPair();
        addTearDown(pair.dispose);
        final container = ProviderContainer(
          overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
        );
        addTearDown(container.dispose);

        final inputs = <SshInputCommand>[];
        final sub = pair.taskSide.incoming.listen((payload) {
          try {
            final cmd = SshTaskCommand.fromJson(payload);
            if (cmd is SshInputCommand) inputs.add(cmd);
          } catch (_) {}
        });
        addTearDown(sub.cancel);

        final entry = container
            .read(sessionsProvider.notifier)
            .addOrActivate(_params());

        _emitState(pair, entry.id, SshSessionState.connected.name);
        await Future<void>.delayed(Duration.zero);
        expect(entry.proxy.data.state, SshSessionState.connected);

        entry.terminal.onOutput?.call('ls\n');
        await Future<void>.delayed(Duration.zero);

        expect(
          inputs,
          isNotEmpty,
          reason: 'keystrokes must still reach the PTY while connected',
        );
      },
    );

    test('soft_disconnected and reconnecting also gate input', () async {
      for (final state in [
        SshSessionState.softDisconnected,
        SshSessionState.reconnecting,
        SshSessionState.failed,
      ]) {
        final pair = InMemoryGatewayPair();
        final container = ProviderContainer(
          overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
        );

        final inputs = <SshInputCommand>[];
        final sub = pair.taskSide.incoming.listen((payload) {
          try {
            final cmd = SshTaskCommand.fromJson(payload);
            if (cmd is SshInputCommand) inputs.add(cmd);
          } catch (_) {}
        });

        final entry = container
            .read(sessionsProvider.notifier)
            .addOrActivate(_params());
        _emitState(pair, entry.id, state.name);
        await Future<void>.delayed(Duration.zero);

        entry.terminal.onOutput?.call('\x1b[<64;12;19M');
        await Future<void>.delayed(Duration.zero);

        expect(inputs, isEmpty, reason: 'input must be gated in $state (#624)');

        await sub.cancel();
        container.dispose();
        await pair.dispose();
      }
    });
  });
}
