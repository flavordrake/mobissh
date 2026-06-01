// Widget tests for terminal gestures (#568).
//
// Phase 1: a horizontal swipe on the bottom session bar switches the active
// session, wrapping around the session ring. A single-session swipe is a
// no-op. These assert at the STATE level (sessionsProvider.activeId) — the
// actual touch feel (velocity, arena negotiation vs. the terminal's vertical
// scroll) requires real-device validation, which a widget test can't cover.
//
// #617: the Phase 2 long-press context menu was removed (owner: useless /
// didn't reliably select-copy), so its tests are gone. tmux scrollback (the
// gesture the menu used to compete with) is now covered by the on-emulator
// integration_test/tmux_scrollback_test.dart.

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

import '../support/fake_ssh_shell_transport.dart';

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
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

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

SshConnectParams _params(String host) => SshConnectParams(
  host: host,
  port: 22,
  username: 'u',
  auth: const SshAuth.password('p'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Phase 1 — session-bar swipe', () {
    testWidgets(
      'swipe left on the session bar advances to the next session in the ring',
      (tester) async {
        final container = _makeContainer();
        addTearDown(container.dispose);

        final notifier = container.read(sessionsProvider.notifier);
        final a = notifier.addOrActivate(_params('host-a'));
        final b = notifier.addOrActivate(_params('host-b'));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TerminalScreen()),
          ),
        );
        await _pumpFrames(tester);

        // b was added last → active. Two sessions form a ring [a, b].
        expect(container.read(sessionsProvider).activeId, b.id);

        // Swipe LEFT (negative dx) on the session bar → next session. From b
        // (index 1) the ring wraps to a (index 0).
        await tester.drag(
          find.byKey(const Key('session-bar')),
          const Offset(-120, 0),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, a.id);

        // Swipe LEFT again → wraps a (index 0) forward to b (index 1).
        await tester.drag(
          find.byKey(const Key('session-bar')),
          const Offset(-120, 0),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, b.id);
      },
    );

    testWidgets(
      'swipe right on the session bar goes to the previous session in the ring',
      (tester) async {
        final container = _makeContainer();
        addTearDown(container.dispose);

        final notifier = container.read(sessionsProvider.notifier);
        final a = notifier.addOrActivate(_params('host-a'));
        final b = notifier.addOrActivate(_params('host-b'));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TerminalScreen()),
          ),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, b.id);

        // Swipe RIGHT (positive dx) → previous session. From b (1) → a (0).
        await tester.drag(
          find.byKey(const Key('session-bar')),
          const Offset(120, 0),
        );
        await _pumpFrames(tester);

        expect(container.read(sessionsProvider).activeId, a.id);
      },
    );

    testWidgets('swipe with a single session is a no-op', (tester) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final a = container
          .read(sessionsProvider.notifier)
          .addOrActivate(_params('solo'));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, a.id);

      await tester.drag(
        find.byKey(const Key('session-bar')),
        const Offset(-200, 0),
      );
      await _pumpFrames(tester);

      // Only one session → still active, no crash, no change.
      expect(container.read(sessionsProvider).activeId, a.id);
    });

    testWidgets('a sub-threshold horizontal drag does not switch sessions', (
      tester,
    ) async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      notifier.addOrActivate(_params('host-a'));
      final b = notifier.addOrActivate(_params('host-b'));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TerminalScreen()),
        ),
      );
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, b.id);

      // 20px < 50px threshold → no switch.
      await tester.drag(
        find.byKey(const Key('session-bar')),
        const Offset(-20, 0),
      );
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).activeId, b.id);
    });
  });
}
