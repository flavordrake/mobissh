// Widget tests for [TerminalScreen].
//
// Phase 2.A (#501): xterm.dart ships with widget tests for the user-facing
// flows.
// Phase 4 (#511): the screen now hosts a multi-session tab strip + IndexedStack.
// Tests populate the sessions collection directly (no global controller).

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

SshSessionController _stubController() => SshSessionController(
      socketOpener: (host, port, {timeout}) =>
          Future<SSHSocket>.delayed(const Duration(days: 1), () {
        throw Exception('not used in widget tests');
      }),
    );

/// Build a scope + populate the session collection with a single entry whose
/// shell uses the supplied fake transport. Returns the populated entry so
/// tests can assert against its terminal.
Future<({SessionEntry entry, ProviderContainer container})> _setupSingleSession(
  WidgetTester tester,
  FakeSshShellTransport transport, {
  String host = 'h',
  int port = 22,
  String username = 'u',
}) async {
  final container = ProviderContainer(
    overrides: [
      sshSessionControllerFactoryProvider.overrideWithValue(_stubController),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => transport,
      ),
    ],
  );

  final entry = container
      .read(sessionsProvider.notifier)
      .addOrActivate(SshConnectParams(
        host: host,
        port: port,
        username: username,
        auth: const SshAuth.password('p'),
      ));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  await tester.pumpAndSettle();

  return (entry: entry, container: container);
}

void main() {
  group('TerminalScreen', () {
    testWidgets('renders a TerminalView', (tester) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final ({SessionEntry entry, ProviderContainer container}) setup =
          await _setupSingleSession(tester, transport);
      addTearDown(setup.container.dispose);

      expect(find.byType(TerminalView), findsWidgets);
    });

    testWidgets('shows host@user:port in the AppBar title', (tester) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final ({SessionEntry entry, ProviderContainer container}) setup =
          await _setupSingleSession(
        tester,
        transport,
        host: 'sshd.example',
        port: 2222,
        username: 'alice',
      );
      addTearDown(setup.container.dispose);

      expect(find.text('alice@sshd.example:2222'), findsWidgets);
    });

    testWidgets('disconnect button is present in the AppBar',
        (tester) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final ({SessionEntry entry, ProviderContainer container}) setup =
          await _setupSingleSession(tester, transport);
      addTearDown(setup.container.dispose);

      final btn = find.byKey(const Key('terminal-disconnect-button'));
      expect(btn, findsOneWidget);
      final iconButton = tester.widget<IconButton>(btn);
      expect(iconButton.onPressed, isNotNull);
    });

    testWidgets('session menu button is present in the AppBar',
        (tester) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final ({SessionEntry entry, ProviderContainer container}) setup =
          await _setupSingleSession(tester, transport);
      addTearDown(setup.container.dispose);

      expect(find.byKey(const Key('session-menu-button')), findsOneWidget);
    });
  });
}
