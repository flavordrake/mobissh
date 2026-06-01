// Router route-stability across a session DROP (#624 root cause).
//
// The device bug: after a live session dropped, the disconnect banner never
// showed because RootRouter navigated AWAY from the terminal screen. The router
// originally routed to TerminalScreen ONLY while some session was `connected`;
// the moment a session left `connected` (→ softDisconnected / reconnecting /
// disconnected / failed) the loop found nothing connected and returned the
// chooser (ConnectHomePage), UNMOUNTING the terminal body + the banner. The
// isolated widget test (disconnect_indicator_test) mounted TerminalScreen
// directly, so it never exercised the router and passed — the headless/route
// gap that shipped the device bug.
//
// These tests mount the REAL RootRouter and drive a session through
// connected → dropped, asserting the terminal screen STAYS mounted (banner
// present) for a kept-but-dead entry, while a never-connected first-attempt
// failure stays on the chooser so the connect error / host-key prompt render
// there.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/main.dart';
import 'package:mobissh/platform/desktop.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

({ProviderContainer container, InMemoryGatewayPair pair}) _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      // NoopKeepaliveGateway path — keeps FlutterForegroundTask statics out of
      // the router's keepaliveControllerProvider read.
      isDesktopProvider.overrideWithValue(true),
      keepaliveServiceStarterProvider.overrideWithValue(() async {}),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => FakeSshShellTransport(),
      ),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return (container: container, pair: pair);
}

void _emit(InMemoryGatewayPair pair, String id, SshSessionState state) {
  pair.taskSide.send(SshStateEvent(sessionId: id, state: state.name).toJson());
}

Future<void> _pump(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RootRouter route stability (#624)', () {
    testWidgets(
      'a kept-but-dead entry KEEPS the terminal screen mounted with the '
      'disconnect banner (does not navigate back to the chooser)',
      (tester) async {
        final c = _makeContainer();
        final entry = c.container
            .read(sessionsProvider.notifier)
            .addOrActivate(
              const SshConnectParams(
                host: 'h',
                port: 22,
                username: 'u',
                auth: SshAuth.password('p'),
              ),
            );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c.container,
            child: const MaterialApp(home: RootRouter()),
          ),
        );
        await _pump(tester);

        // Reach the terminal screen by going `connected` first.
        _emit(c.pair, entry.id, SshSessionState.connected);
        await _pump(tester);
        expect(
          find.byKey(const Key('session-menu-button')),
          findsOneWidget,
          reason: 'router should show the terminal screen while connected',
        );
        expect(
          find.byKey(const Key('terminal-disconnect-banner')),
          findsNothing,
        );

        // Now DROP the session (clean disconnect → `disconnected`). The entry
        // STAYS in the collection (the Disconnect BUTTON would close() it; a
        // network drop / programmatic disconnect does not).
        _emit(c.pair, entry.id, SshSessionState.disconnected);
        await _pump(tester);

        // The terminal screen must STILL be mounted (root-cause fix): the
        // session menu button is the stable terminal-screen marker.
        expect(
          find.byKey(const Key('session-menu-button')),
          findsOneWidget,
          reason:
              'router must KEEP the terminal screen for a kept-but-dead entry '
              '(#624) — not navigate back to the chooser',
        );
        // And the disconnect banner must show.
        expect(
          find.byKey(const Key('terminal-disconnect-banner')),
          findsOneWidget,
          reason: 'disconnect banner must be visible on the kept terminal',
        );
      },
    );

    testWidgets(
      'a genuine drop (softDisconnected → reconnecting) keeps the terminal '
      'screen + banner mounted',
      (tester) async {
        final c = _makeContainer();
        final entry = c.container
            .read(sessionsProvider.notifier)
            .addOrActivate(
              const SshConnectParams(
                host: 'h',
                port: 22,
                username: 'u',
                auth: SshAuth.password('p'),
              ),
            );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c.container,
            child: const MaterialApp(home: RootRouter()),
          ),
        );
        await _pump(tester);

        _emit(c.pair, entry.id, SshSessionState.connected);
        await _pump(tester);

        // Drop: connected → softDisconnected → reconnecting (#551). Both must
        // keep the terminal mounted with the banner.
        _emit(c.pair, entry.id, SshSessionState.softDisconnected);
        await _pump(tester);
        expect(find.byKey(const Key('session-menu-button')), findsOneWidget);
        expect(
          find.byKey(const Key('terminal-disconnect-banner')),
          findsOneWidget,
        );

        _emit(c.pair, entry.id, SshSessionState.reconnecting);
        await _pump(tester);
        expect(find.byKey(const Key('session-menu-button')), findsOneWidget);
        expect(
          find.byKey(const Key('terminal-disconnect-banner')),
          findsOneWidget,
        );

        // Reconnect succeeds → banner clears, terminal stays.
        _emit(c.pair, entry.id, SshSessionState.connected);
        await _pump(tester);
        expect(find.byKey(const Key('session-menu-button')), findsOneWidget);
        expect(
          find.byKey(const Key('terminal-disconnect-banner')),
          findsNothing,
        );
      },
    );

    testWidgets('a NEVER-connected first-attempt failure stays on the chooser '
        '(so the connect error / host-key prompt render there)', (
      tester,
    ) async {
      final c = _makeContainer();
      final entry = c.container
          .read(sessionsProvider.notifier)
          .addOrActivate(
            const SshConnectParams(
              host: 'h',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c.container,
          child: const MaterialApp(home: RootRouter()),
        ),
      );
      await _pump(tester);

      // First connect never reaches `connected`; it fails (auth/unreachable).
      _emit(c.pair, entry.id, SshSessionState.connecting);
      await _pump(tester);
      _emit(c.pair, entry.id, SshSessionState.failed);
      await _pump(tester);

      // The router must NOT show the terminal for a session that was never
      // live — the chooser owns the connect-error / host-key UX.
      expect(
        find.byKey(const Key('session-menu-button')),
        findsNothing,
        reason:
            'a never-connected failed entry must stay on the chooser '
            '(no terminal screen)',
      );
    });

    testWidgets(
      'closing the only session (entry removed) returns to the chooser',
      (tester) async {
        final c = _makeContainer();
        final notifier = c.container.read(sessionsProvider.notifier);
        final entry = notifier.addOrActivate(
          const SshConnectParams(
            host: 'h',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c.container,
            child: const MaterialApp(home: RootRouter()),
          ),
        );
        await _pump(tester);
        _emit(c.pair, entry.id, SshSessionState.connected);
        await _pump(tester);
        expect(find.byKey(const Key('session-menu-button')), findsOneWidget);

        // The Disconnect button removes the entry from the collection.
        notifier.close(entry.id);
        await _pump(tester);

        expect(
          find.byKey(const Key('session-menu-button')),
          findsNothing,
          reason: 'an empty collection returns to the chooser',
        );
      },
    );
  });
}
