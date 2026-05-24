// Widget smoketest: multi-session via the session menu on TerminalScreen
// (#511, refreshed for #518 — chip strip replaced by a session menu).
//
// Two sessions in the collection → tapping the AppBar menu icon opens a
// bottom sheet listing both sessions. Tapping the inactive one switches
// `activeSessionId` and dismisses the menu.

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

SshSessionController _stubController() => SshSessionController(
      socketOpener: (host, port, {timeout}) =>
          Future<SSHSocket>.delayed(const Duration(days: 1), () {
        throw Exception('not used in widget tests');
      }),
    );

ProviderContainer _makeContainer() {
  return ProviderContainer(
    overrides: [
      sshSessionControllerFactoryProvider.overrideWithValue(_stubController),
      sshShellOpenerProvider.overrideWithValue(
          (ref, sessionId, terminal) async => FakeSshShellTransport()),
    ],
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('TerminalScreen multi-session', () {
    testWidgets('session menu icon is rendered in the AppBar',
        (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      container.read(sessionsProvider.notifier).addOrActivate(
            const SshConnectParams(
              host: 'host-a',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      expect(find.byKey(const Key('session-menu-button')), findsOneWidget);
    });

    testWidgets(
        'opening the session menu lists every session and tapping an '
        'inactive row switches activeSessionId', (tester) async {
      final container = _makeContainer();
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

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      // Sanity: b was the last addOrActivate, so it's active.
      expect(container.read(sessionsProvider).activeId, b.id);

      // Open the session menu.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await _pumpFrames(tester);

      // Both session rows are visible.
      expect(find.byKey(const Key('session-menu')), findsOneWidget);
      expect(find.byKey(Key('session-menu-row-${a.id}')), findsOneWidget);
      expect(find.byKey(Key('session-menu-row-${b.id}')), findsOneWidget);

      // Tap session A's row — active id should swap and the menu closes.
      await tester.tap(find.byKey(Key('session-menu-row-${a.id}')));
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, a.id);
      expect(find.byKey(const Key('session-menu')), findsNothing);
    });
  });
}
