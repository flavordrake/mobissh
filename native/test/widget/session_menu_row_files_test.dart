// Per-row file icon on the session menu (#649).
//
// Owner: "the file icon should be attached to the session line item next to the
// x to disconnect." The slim session menu (#567) lists each active session as a
// row `[color dot] label  [X]` where X disconnects THAT session. This adds a
// FILE icon on EACH row, next to that row's X, opening the file browser for
// THAT row's sessionId (reusing the existing openFileBrowser/FileBrowserScreen
// route). The X (disconnect/close) must stay intact.
//
// These tests assert per-row behaviour (not active-only): with multiple
// sessions, each row owns its own file icon, and tapping row A's icon opens the
// browser for A — not the active session.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host) {
  return c
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );
}

Widget _host({required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              key: const Key('open-menu'),
              onPressed: () => showSessionMenu(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
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

  group('Session menu per-row file icon (#649)', () {
    testWidgets('each session row renders its own file icon next to the X', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // One file icon per row, keyed by that row's session id.
      expect(find.byKey(Key('session-menu-files-${a.id}')), findsOneWidget);
      expect(find.byKey(Key('session-menu-files-${b.id}')), findsOneWidget);

      // The X (close) icon per row remains intact.
      expect(find.byKey(Key('session-menu-close-${a.id}')), findsOneWidget);
      expect(find.byKey(Key('session-menu-close-${b.id}')), findsOneWidget);
    });

    testWidgets('tapping a row file icon opens the browser for THAT row', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      _add(container, 'host-b'); // b is active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Tap the file icon on the NON-active row (a). It must open the browser
      // for a's session, not the active session (b).
      await tester.tap(find.byKey(Key('session-menu-files-${a.id}')));
      await _pumpFrames(tester);

      final browser = tester.widget<FileBrowserScreen>(
        find.byType(FileBrowserScreen),
      );
      expect(browser.sessionId, a.id);
    });

    testWidgets('the row X still disconnects/closes that session', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      _add(container, 'host-b');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(container.read(sessionsProvider).entries.length, 2);

      await tester.tap(find.byKey(Key('session-menu-close-${a.id}')));
      await _pumpFrames(tester);

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 1);
      expect(entries.any((e) => e.id == a.id), isFalse);
    });
  });
}
