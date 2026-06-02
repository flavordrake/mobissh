// #613 — connecting from a profile applies its default theme to THAT session.
//
// profile.theme used to be dead data on native (stored + imported, never
// applied). This locks the wiring: tapping a profile whose theme is 'dracula'
// must set the NEW session's per-session appearance theme (#601) to the dracula
// palette — keyed by the session id, NOT global. A second session connected from
// a profile WITHOUT a theme stays the default (per-session isolation; memory:
// feedback_feature_scoping_and_isolation_tests).
//
// Drives the real ConnectForm connect path (addOrActivate → proxy.connect) with
// an in-memory gateway, then asserts via sessionThemeProvider on the created
// entry's id.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/connect_form.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 30}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required ProfilesStore store,
  required SecretsStore secrets,
}) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async {
    await pair.dispose();
  });
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
      secretsStoreProvider.overrideWithValue(secrets),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: ConnectForm()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('connecting a profile with theme=dracula themes that session', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Dark box',
        host: 'dracula.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-1',
        theme: 'dracula',
      ),
    ]);

    final container = await _pump(tester, store: store, secrets: secrets);

    await tester.tap(
      find.byKey(const Key('profile-tile-dracula.example:22:alice')),
    );
    await _pumpFrames(tester);

    final entries = container.read(sessionsProvider).entries;
    expect(entries.length, 1);
    final id = entries.first.id;

    final draculaIdx = paletteIndexForThemeName('dracula');
    expect(
      container.read(sessionThemeProvider(id)),
      draculaIdx,
      reason: 'session must open in the profile\'s configured theme',
    );
    expect(container.read(sessionTerminalThemeProvider(id)).label, 'Dracula');
  });

  testWidgets(
    'a second session WITHOUT a profile theme stays default (isolation)',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await secrets.write('vault-2', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Themed',
          host: 'dracula.example',
          port: 22,
          username: 'alice',
          authType: 'password',
          vaultId: 'vault-1',
          theme: 'dracula',
        ),
        SavedProfile(
          title: 'Plain',
          host: 'plain.example',
          port: 22,
          username: 'bob',
          authType: 'password',
          vaultId: 'vault-2',
          // no theme
        ),
      ]);

      final container = await _pump(tester, store: store, secrets: secrets);

      await tester.tap(
        find.byKey(const Key('profile-tile-dracula.example:22:alice')),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const Key('profile-tile-plain.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 2);
      final themed = entries.firstWhere((e) => e.host == 'dracula.example');
      final plain = entries.firstWhere((e) => e.host == 'plain.example');

      expect(
        container.read(sessionThemeProvider(themed.id)),
        paletteIndexForThemeName('dracula'),
      );
      expect(
        container.read(sessionThemeProvider(plain.id)),
        terminalThemeDefault,
        reason: 'a profile without a theme must not inherit the themed one',
      );
    },
  );

  testWidgets(
    'connecting a profile with an unknown theme falls back to default',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Mystery',
          host: 'mystery.example',
          port: 22,
          username: 'alice',
          authType: 'password',
          vaultId: 'vault-1',
          theme: 'no-such-theme',
        ),
      ]);

      final container = await _pump(tester, store: store, secrets: secrets);

      await tester.tap(
        find.byKey(const Key('profile-tile-mystery.example:22:alice')),
      );
      await _pumpFrames(tester);

      final id = container.read(sessionsProvider).entries.first.id;
      expect(container.read(sessionThemeProvider(id)), terminalThemeDefault);
    },
  );
}
