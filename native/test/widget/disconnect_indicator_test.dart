// Issue #624: the terminal screen must show a clear, state-driven disconnect
// indicator when the active session is NOT `connected` (soft_disconnected /
// reconnecting / failed / disconnected), and hide it when connected.
//
// The indicator reads the session lifecycle enum directly (no parallel boolean,
// per rules/state-management.md). These tests drive the per-session proxy state
// through the InMemoryGatewayPair and assert the banner's presence/absence by
// its stable key `terminal-disconnect-banner`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<
  ({SessionEntry entry, ProviderContainer container, InMemoryGatewayPair pair})
>
_setup(WidgetTester tester) async {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(() async {
    await pair.dispose();
  });
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

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  return (entry: entry, container: container, pair: pair);
}

void _emitState(InMemoryGatewayPair pair, String sessionId, String state) {
  pair.taskSide.send(
    SshStateEvent(sessionId: sessionId, state: state).toJson(),
  );
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('disconnect indicator (#624)', () {
    testWidgets('shows the banner when the session is disconnected', (
      tester,
    ) async {
      final s = await _setup(tester);
      _emitState(s.pair, s.entry.id, SshSessionState.disconnected.name);
      await _pump(tester);

      expect(
        find.byKey(const Key('terminal-disconnect-banner')),
        findsOneWidget,
      );
    });

    testWidgets('hides the banner when the session is connected', (
      tester,
    ) async {
      final s = await _setup(tester);
      _emitState(s.pair, s.entry.id, SshSessionState.connected.name);
      await _pump(tester);

      expect(find.byKey(const Key('terminal-disconnect-banner')), findsNothing);
    });

    testWidgets('shows the banner while reconnecting', (tester) async {
      final s = await _setup(tester);
      _emitState(s.pair, s.entry.id, SshSessionState.reconnecting.name);
      await _pump(tester);

      expect(
        find.byKey(const Key('terminal-disconnect-banner')),
        findsOneWidget,
      );
    });

    testWidgets('banner appears then clears across a disconnect→reconnect', (
      tester,
    ) async {
      final s = await _setup(tester);
      _emitState(s.pair, s.entry.id, SshSessionState.connected.name);
      await _pump(tester);
      expect(find.byKey(const Key('terminal-disconnect-banner')), findsNothing);

      _emitState(s.pair, s.entry.id, SshSessionState.softDisconnected.name);
      await _pump(tester);
      expect(
        find.byKey(const Key('terminal-disconnect-banner')),
        findsOneWidget,
      );

      _emitState(s.pair, s.entry.id, SshSessionState.connected.name);
      await _pump(tester);
      expect(find.byKey(const Key('terminal-disconnect-banner')), findsNothing);
    });
  });
}
