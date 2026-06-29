// Per-row favorites star on the session menu (#950).
//
// Owner: "every session with marked favorites needs a favorite icon (opens
// favorites scoped to that session/profile)." Each session row shows a star
// ONLY when THAT row's profile (host:port:username) has marked favorites.
// Tapping it opens the shared profile-scoped favorites sheet; tapping a favorite
// closes the menu and opens the file browser for THAT session at the path.
//
// These assert per-profile scoping: a session whose profile has favorites shows
// the star; one without does not; and the favorite opens the browser for the
// right session.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
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

  group('Session menu per-row favorites star (#950)', () {
    testWidgets('star shows only on a row whose profile has favorites', (
      tester,
    ) async {
      // host-a's profile has a favorite; host-b's does not.
      await FavoritesStore().add('host-a:22:u', '/srv/app');

      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(find.byKey(Key('session-menu-favorites-${a.id}')), findsOneWidget);
      expect(find.byKey(Key('session-menu-favorites-${b.id}')), findsNothing);
    });

    testWidgets('tapping the star opens that profile\'s favorites, and a '
        'favorite opens the browser for that session', (tester) async {
      await FavoritesStore().add('host-a:22:u', '/srv/app');

      final container = _makeContainer();
      final a = _add(container, 'host-a');
      _add(container, 'host-b'); // b is active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(Key('session-menu-favorites-${a.id}')));
      await _pumpFrames(tester);

      // The scoped favorites sheet lists host-a's favorite.
      expect(find.byKey(const Key('favorites-list')), findsOneWidget);
      expect(
        find.byKey(const Key('favorite-item-/srv/app')),
        findsOneWidget,
      );

      // Tapping it opens the file browser for host-a (not the active host-b) at
      // the favorite path.
      await tester.tap(find.byKey(const Key('favorite-item-/srv/app')));
      await _pumpFrames(tester);

      final browser = tester.widget<FileBrowserScreen>(
        find.byType(FileBrowserScreen),
      );
      expect(browser.sessionId, a.id);
      expect(browser.initialPath, '/srv/app');
    });
  });
}
