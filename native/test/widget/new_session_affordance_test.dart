// Widget test: the "Profiles & settings" affordance (goal leg 2, #721).
//
// The multi-session model (SessionsNotifier) supports N sessions, but until
// this affordance there was no UI path to start a SECOND one — and, separately
// (#721), no way to reach profiles + every setting from a LIVE session without
// disconnecting all of them. RootRouter binary-swaps to the terminal the moment
// any session connects, so ConnectHomePage (the only place with Profiles +
// Settings + Diagnostics) was reachable ONLY with zero connected sessions.
//
// #721: the session menu's tile now opens the FULL ConnectHomePage (the SAME
// unified view as first-run) PUSHED over the live terminal, NOT a reduced
// connect form. This test locks the wiring:
//
//   1. The session menu renders the tile (`session-menu-new`).
//   2. Tapping it closes the menu and pushes ConnectHomePage — with the
//      Settings/Diagnostics bottom-nav (`home-bottom-nav`) AND a back-to-session
//      affordance (`home-back-to-session`) — while the existing session stays
//      connected (NOT closed).
//   3. Picking "New connection" -> Save&connect adds a second session.
//   4. Tapping back returns to the terminal with both sessions intact.
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

  testWidgets('session menu offers the profiles/settings tile', (tester) async {
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
    '#721: tile opens the FULL home (Profiles/Settings/Diagnostics) over the '
    'live session WITHOUT closing it',
    (tester) async {
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

      // Open the session menu and tap the profiles/settings tile.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('session-menu-new')));
      await _pumpFrames(tester);

      // The menu is gone and the FULL ConnectHomePage is pushed on top: it has
      // the Settings/Diagnostics bottom-nav (the unified view, NOT a reduced
      // connect form) AND a back-to-session affordance.
      expect(find.byKey(const Key('session-menu')), findsNothing);
      expect(find.byKey(const Key('home-bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('home-nav-settings')), findsOneWidget);
      expect(find.byKey(const Key('home-nav-diagnostics')), findsOneWidget);
      expect(find.byKey(const Key('home-back-to-session')), findsOneWidget);

      // CRITICAL (#721): the existing session was NOT torn down by opening the
      // home — it persists underneath so its keep-alive holds.
      expect(container.read(sessionsProvider).entries.length, 1);
      expect(container.read(sessionsProvider).entries.first.id, a.id);

      // Settings is reachable right here (the whole point): switch to it.
      await tester.tap(find.byKey(const Key('home-nav-settings')));
      await _pumpFrames(tester);

      // Back returns to the live terminal; the session is still there. Pump
      // generously so the route pop transition fully completes (the terminal
      // body re-arms fit timers continuously, so pumpAndSettle would never
      // quiesce — use discrete frames instead).
      await tester.tap(find.byKey(const Key('home-back-to-session')));
      await _pumpFrames(tester, count: 20);
      expect(find.byKey(const Key('home-bottom-nav')), findsNothing);
      expect(find.byKey(const Key('session-bar')), findsOneWidget);
      expect(container.read(sessionsProvider).entries.length, 1);
      expect(container.read(sessionsProvider).entries.first.id, a.id);
    },
  );

  testWidgets(
    '#721: from the pushed home, New -> Save&connect adds a 2nd session '
    '(both sessions persist)',
    (tester) async {
      // #583: starting an ad-hoc session goes through the editor: "New
      // connection" -> fill -> "Save & connect". The chooser lives inside the
      // pushed ConnectHomePage now (#721) instead of a standalone page.
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

      // Open the session menu and open the profiles/settings home.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('session-menu-new')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('home-bottom-nav')), findsOneWidget);

      // Open the editor in create mode via the "New connection" affordance
      // (the Profiles tab is selected by default).
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

      // A second session now exists and is active — and the FIRST one was NOT
      // dropped. The pushed route stays mounted until its session reaches
      // `connected` (so host-key prompts still render); the in-memory gateway
      // here never emits `connected`, so we don't assert pop.
      final state = container.read(sessionsProvider);
      expect(state.entries.length, 2);
      expect(state.entries.any((e) => e.id == a.id), isTrue);
      expect(state.activeId, isNot(a.id));
      expect(state.active?.host, 'host-b');
    },
  );
}
