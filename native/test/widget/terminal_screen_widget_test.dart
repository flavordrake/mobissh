// Widget tests for [TerminalScreen].
//
// Phase 2.A (#501): xterm.dart ships with widget tests for the user-facing
// flows.
// Phase 4 (#511): the screen now hosts a multi-session tab strip + IndexedStack.
// Tests populate the sessions collection directly (no global controller).
//
// #533: sessions are proxy-backed; tests override `taskSshGatewayProvider`
// with an in-memory gateway pair so the proxy + notifier wiring is exercised
// without binding to FFT statics.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

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
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => transport,
      ),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });

  final entry = container
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: port,
          username: username,
          auth: const SshAuth.password('p'),
        ),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  // Bounded pump — pumpAndSettle can hang on the proxy's idle event stream.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }

  return (entry: entry, container: container);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('bottom-chrome reserve constants (#615)', () {
    test('session bar reserve is reduced ~25% from the old 48px', () {
      // The compose-bar bottomReserve used a hardcoded 48 for the session bar.
      expect(kSessionBarReserve, lessThanOrEqualTo(40));
      expect(kSessionBarReserve, greaterThanOrEqualTo(32));
    });
  });

  group('TerminalScreen', () {
    testWidgets('renders a TerminalView', (tester) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final ({SessionEntry entry, ProviderContainer container}) setup =
          await _setupSingleSession(tester, transport);
      addTearDown(setup.container.dispose);

      expect(find.byType(TerminalView), findsWidgets);
    });

    testWidgets('shows host@user:port label on the bottom session bar', (
      tester,
    ) async {
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

    // #607: the bar's right-edge button is now the COMPOSE-bar toggle, not
    // disconnect. Disconnect moved into the session menu (it's infrequent).
    testWidgets(
      'compose toggle is on the bottom session bar; disconnect is not',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final ({SessionEntry entry, ProviderContainer container}) setup =
            await _setupSingleSession(tester, transport);
        addTearDown(setup.container.dispose);

        final toggle = find.byKey(const Key('session-bar-compose-toggle'));
        expect(toggle, findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('session-bar')),
            matching: toggle,
          ),
          findsOneWidget,
        );
        final iconButton = tester.widget<IconButton>(toggle);
        expect(iconButton.onPressed, isNotNull);

        // Disconnect is NO LONGER on the bar (it lives in the session menu now).
        expect(
          find.descendant(
            of: find.byKey(const Key('session-bar')),
            matching: find.byKey(const Key('terminal-disconnect-button')),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'session menu button is present (now on the bottom bar, #566)',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final ({SessionEntry entry, ProviderContainer container}) setup =
            await _setupSingleSession(tester, transport);
        addTearDown(setup.container.dispose);

        expect(find.byKey(const Key('session-menu-button')), findsOneWidget);
      },
    );

    testWidgets(
      'terminal screen has NO top AppBar — full-height terminal (#566)',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final ({SessionEntry entry, ProviderContainer container}) setup =
            await _setupSingleSession(tester, transport);
        addTearDown(setup.container.dispose);

        // Terminal real estate is at a premium: there is NO AppBar; the
        // session label + menu trigger + disconnect all live on the bottom
        // session bar. Guard against a regression that re-adds a top AppBar.
        expect(find.byType(AppBar), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('session-bar')),
            matching: find.byKey(const Key('session-menu-button')),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('bottom session bar is present and addressable (#566)', (
      tester,
    ) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final ({SessionEntry entry, ProviderContainer container}) setup =
          await _setupSingleSession(tester, transport);
      addTearDown(setup.container.dispose);

      expect(find.byKey(const Key('session-bar')), findsOneWidget);
      expect(find.byKey(const Key('session-bar-open-menu')), findsOneWidget);
    });

    testWidgets(
      'tapping the bottom session bar opens the session menu (#566)',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final ({SessionEntry entry, ProviderContainer container}) setup =
            await _setupSingleSession(tester, transport);
        addTearDown(setup.container.dispose);

        expect(find.byKey(const Key('session-menu')), findsNothing);

        await tester.tap(find.byKey(const Key('session-bar-open-menu')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.byKey(const Key('session-menu')), findsOneWidget);
      },
    );
  });
}
