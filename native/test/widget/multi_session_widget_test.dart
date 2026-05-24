// Widget smoketest: multi-session tab strip on TerminalScreen (#511).
//
// Two sessions in the collection → two tab chips render and the active
// chip changes when we tap the other tab.

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';

import '../support/fake_ssh_shell_transport.dart';

SshSessionController _stubController() => SshSessionController(
      socketOpener: (host, port, {timeout}) =>
          Future<SSHSocket>.delayed(const Duration(days: 1), () {
        throw Exception('not used in widget tests');
      }),
    );

ProviderScope _buildScope() {
  return ProviderScope(
    overrides: [
      sshSessionControllerFactoryProvider.overrideWithValue(_stubController),
      // Replace the shell opener with a fake transport per session so the
      // shell provider resolves without real SSH plumbing. Returning null
      // when the session isn't connected matches production behavior.
      sshShellOpenerProvider.overrideWithValue((ref, sessionId, terminal) async {
        return FakeSshShellTransport();
      }),
    ],
    child: const MaterialApp(home: TerminalScreen()),
  );
}

void main() {
  group('TerminalScreen multi-session', () {
    testWidgets('renders one tab chip per session', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        Builder(builder: (ctx) {
          final scope = _buildScope();
          return UncontrolledProviderScope(
            container: container = ProviderContainer(
              overrides: scope.overrides.toList(),
            ),
            child: const MaterialApp(home: TerminalScreen()),
          );
        }),
      );
      addTearDown(container.dispose);

      // Pre-populate two sessions before settling.
      final notifier = container.read(sessionsProvider.notifier);
      notifier.addOrActivate(const SshConnectParams(
        host: 'host-a',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      final b = notifier.addOrActivate(const SshConnectParams(
        host: 'host-b',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      await tester.pumpAndSettle();

      expect(find.byKey(const Key('session-tab-strip')), findsOneWidget);
      // Two tab chips → both keys present.
      expect(find.byKey(Key('session-tab-${b.id}')), findsOneWidget);
      expect(container.read(sessionsProvider).entries, hasLength(2));
    });

    testWidgets('tapping an inactive tab switches activeSessionId',
        (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        Builder(builder: (ctx) {
          final scope = _buildScope();
          return UncontrolledProviderScope(
            container: container = ProviderContainer(
              overrides: scope.overrides.toList(),
            ),
            child: const MaterialApp(home: TerminalScreen()),
          );
        }),
      );
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(const SshConnectParams(
        host: 'host-a',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      final b = notifier.addOrActivate(const SshConnectParams(
        host: 'host-b',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      await tester.pumpAndSettle();

      expect(container.read(sessionsProvider).activeId, b.id);

      // Tap session A's tab — active id should swap.
      await tester.tap(find.byKey(Key('session-tab-${a.id}')));
      await tester.pumpAndSettle();

      expect(container.read(sessionsProvider).activeId, a.id);
    });
  });
}
