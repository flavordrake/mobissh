// Widget test: the "New session" affordance (goal leg 2).
//
// The multi-session model (SessionsNotifier) supports N sessions, but until
// this affordance there was no UI path to start a SECOND one: RootRouter shows
// the terminal screen the moment any session connects, and neither the AppBar
// nor the session menu offered a "connect another" entry point. This test
// locks the wiring:
//
//   1. The session menu renders a "New session" tile.
//   2. Tapping it closes the menu and pushes the connect form (NewSessionPage).
//   3. Submitting the form adds a second session, makes it active, and pops
//      back to the terminal screen.
//
// Sessions are proxy-backed; `taskSshGatewayProvider` is overridden with an
// in-memory gateway pair so addOrActivate + proxy.connect run without binding
// to FFT statics. `sshShellOpenerProvider` is faked so TerminalScreen's
// per-session TerminalView doesn't open a real PTY.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      // The "New connection" → editor → "Save & connect" flow writes the
      // credential through secretsStore and reads it back to connect, so both
      // stores must be in-memory test seams (the default secure storage has no
      // platform channel under flutter_test).
      profilesStoreProvider.overrideWithValue(ProfilesStore()),
      secretsStoreProvider.overrideWithValue(
        SecretsStore(backend: InMemorySecretsBackend()),
      ),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => FakeSshShellTransport(),
      ),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  return container;
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('session menu offers a "New session" tile', (tester) async {
    final container = _makeContainer();
    addTearDown(container.dispose);

    container
        .read(sessionsProvider.notifier)
        .addOrActivate(
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

    await tester.tap(find.byKey(const Key('session-menu-button')));
    await _pumpFrames(tester);

    expect(find.byKey(const Key('session-menu-new')), findsOneWidget);
  });

  testWidgets(
    'New session: menu -> chooser -> New -> Save&connect adds a 2nd session',
    (tester) async {
      // #583: the new-session page is the profile CHOOSER now (no inline form).
      // Starting an ad-hoc 2nd session goes through the editor: "New connection"
      // -> fill the editor -> "Save & connect".
      final container = _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(
        const SshConnectParams(
          host: 'host-a',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      expect(container.read(sessionsProvider).entries.length, 1);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      // Open the session menu and tap "New session".
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('session-menu-new')));
      await _pumpFrames(tester);

      // The menu is gone and the chooser is pushed on top — NOT a form.
      expect(find.byKey(const Key('session-menu')), findsNothing);
      expect(find.byKey(const Key('new-session-page')), findsOneWidget);
      expect(find.byKey(const Key('new-session-form')), findsOneWidget);

      // Open the editor in create mode via the "New connection" affordance.
      await tester.tap(find.byKey(const Key('new-connection')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('profile-editor')), findsOneWidget);

      // Fill a DIFFERENT host:port:username so addOrActivate creates a new
      // entry (not a dedup-activate of host-a).
      await tester.enterText(
        find.byKey(const Key('profile-editor-host')),
        'host-b',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-port')),
        '22',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-username')),
        'u',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-password')),
        'p2',
      );
      await _pumpFrames(tester);

      // "Save & connect" persists the profile then routes through the chooser's
      // shared connect path.
      final submit = find.byKey(const Key('connect-submit'));
      await tester.ensureVisible(submit);
      await _pumpFrames(tester);
      await tester.tap(submit);
      await _pumpFrames(tester, count: 30);

      // A second session now exists and is active. The pushed route stays
      // mounted until its session reaches `connected` (so host-key prompts
      // still render on the chooser) — that pop is exercised by the emulator
      // integration test (`multi_session_lifecycle_test.dart`); the in-memory
      // gateway here never emits a `connected` state, so we don't assert pop.
      final state = container.read(sessionsProvider);
      expect(state.entries.length, 2);
      expect(state.activeId, isNot(a.id));
      expect(state.active?.host, 'host-b');
    },
  );
}
