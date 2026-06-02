// Widget tests for PER-SESSION keybar visibility (#573).
//
// Keybar visibility used to be a single GLOBAL flag, so toggling it changed the
// keybar for EVERY session. #573 makes it per-session (keyed by session id) on
// `SessionAppearance`, defaulting to visible. The whole point of the issue is
// ISOLATION: hiding the keybar on session A must leave session B's keybar
// visible, and switching the active session must surface each session's own
// state. These tests assert exactly that — both at the state layer
// (`sessionKeybarVisibleProvider`) and at the render layer (the `Keybar` widget
// mounting on TerminalScreen for the ACTIVE session only).
//
// Harness mirrors terminal_remeasure_test.dart / session_bar_swatch_test.dart:
// an InMemoryGatewayPair + a real SshShell per session attached to that
// session's terminal so TerminalScreen mounts the chrome (keybar + session bar).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/keybar.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

/// Mount TerminalScreen with TWO shell-ready sessions (a, b). Returns the two
/// entries + the container so a test can read/mutate per-session keybar state
/// and switch the active session. b is active on mount (last added).
Future<({SessionEntry a, SessionEntry b, ProviderContainer container})>
_mountTwo(WidgetTester tester) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());

  // One transport per session so each shell drives its own terminal.
  final transports = <String, FakeSshShellTransport>{};

  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      // Attach a real shell to THIS session's terminal so the body reaches the
      // connected/shell-ready state and TerminalScreen renders its chrome.
      sshShellProvider.overrideWith((ref, sessionId) async {
        final entry = ref
            .read(sessionsProvider)
            .entries
            .firstWhere((e) => e.id == sessionId);
        final transport = transports.putIfAbsent(
          sessionId,
          FakeSshShellTransport.new,
        );
        final shell = SshShell(transport);
        shell.attach(entry.terminal);
        ref.onDispose(shell.dispose);
        return shell;
      }),
    ],
  );
  addTearDown(() {
    for (final t in transports.values) {
      t.close();
    }
    container.dispose();
  });

  final notifier = container.read(sessionsProvider.notifier);
  final a = notifier.addOrActivate(
    const SshConnectParams(
      host: 'host-a',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ),
    title: 'Session A',
  );
  final b = notifier.addOrActivate(
    const SshConnectParams(
      host: 'host-b',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ),
    title: 'Session B',
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (a: a, b: b, container: container);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('per-session keybar visibility (#573) — state', () {
    test('a fresh session defaults to keybar visible', () {
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(container.dispose);

      final entry = container
          .read(sessionsProvider.notifier)
          .addOrActivate(
            const SshConnectParams(
              host: 'h',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
          );

      expect(container.read(sessionKeybarVisibleProvider(entry.id)), isTrue);
    });

    test('toggling one session does NOT change another (isolation)', () {
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(
        const SshConnectParams(
          host: 'a',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      final b = notifier.addOrActivate(
        const SshConnectParams(
          host: 'b',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );

      final appearance = container.read(sessionAppearanceProvider.notifier);

      // Hide a's keybar — b must stay visible.
      appearance.toggleKeybarVisible(a.id);
      expect(container.read(sessionKeybarVisibleProvider(a.id)), isFalse);
      expect(
        container.read(sessionKeybarVisibleProvider(b.id)),
        isTrue,
        reason: 'b keybar must not change when a is toggled (#573)',
      );

      // Hide b too — a must remain hidden (independent state).
      appearance.toggleKeybarVisible(b.id);
      expect(container.read(sessionKeybarVisibleProvider(a.id)), isFalse);
      expect(container.read(sessionKeybarVisibleProvider(b.id)), isFalse);

      // Show a again — b stays hidden.
      appearance.toggleKeybarVisible(a.id);
      expect(container.read(sessionKeybarVisibleProvider(a.id)), isTrue);
      expect(container.read(sessionKeybarVisibleProvider(b.id)), isFalse);
    });

    test('setKeybarVisible affects only the named session', () {
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(
        const SshConnectParams(
          host: 'a',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      final b = notifier.addOrActivate(
        const SshConnectParams(
          host: 'b',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );

      container
          .read(sessionAppearanceProvider.notifier)
          .setKeybarVisible(a.id, false);
      expect(container.read(sessionKeybarVisibleProvider(a.id)), isFalse);
      expect(container.read(sessionKeybarVisibleProvider(b.id)), isTrue);
    });
  });

  group('per-session keybar visibility (#573) — render', () {
    testWidgets(
      'hiding the active session keybar leaves the other visible on switch',
      (tester) async {
        final m = await _mountTwo(tester);

        // Both default visible; the keybar renders for the active session (b).
        expect(find.byType(Keybar), findsOneWidget);

        // Hide the ACTIVE session (b) keybar.
        m.container
            .read(sessionAppearanceProvider.notifier)
            .setKeybarVisible(m.b.id, false);
        await tester.pump();

        // b is active and hidden → no keybar rendered.
        expect(
          find.byType(Keybar),
          findsNothing,
          reason: 'active session (b) keybar hidden → not rendered',
        );

        // Switch to a — a still defaults to visible, so the keybar reappears.
        m.container.read(sessionsProvider.notifier).setActive(m.a.id);
        await tester.pump();

        expect(
          find.byType(Keybar),
          findsOneWidget,
          reason:
              'sibling session (a) keybar stayed visible — no leakage (#573)',
        );

        // Switch back to b — still hidden (b kept its own state).
        m.container.read(sessionsProvider.notifier).setActive(m.b.id);
        await tester.pump();
        expect(
          find.byType(Keybar),
          findsNothing,
          reason: 'b kept its own hidden state across the switch',
        );
      },
    );

    testWidgets(
      'the session-menu keybar toggle hides only the active session',
      (tester) async {
        final m = await _mountTwo(tester);

        // Open the session menu from the bottom session bar.
        await tester.tap(find.byKey(const Key('session-bar-open-menu')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Toggle the keybar — active session is b.
        await tester.tap(find.byKey(const Key('session-menu-keybar-toggle')));
        await tester.pump();

        expect(m.container.read(sessionKeybarVisibleProvider(m.b.id)), isFalse);
        expect(
          m.container.read(sessionKeybarVisibleProvider(m.a.id)),
          isTrue,
          reason: 'toggling b via the menu must not change a (#573)',
        );
      },
    );
  });
}
