// #640 — connecting from a profile seeds its persisted font size into THAT
// session (mirrors #613 per-profile theme seeding). profile.fontSize used to be
// in-memory per-session only (#616) and never persisted; this locks the seed:
// tapping a profile whose fontSize is 20 must set the NEW session's per-session
// font to 20 — keyed by the session id, NOT global. A second session connected
// from a profile WITHOUT a fontSize stays the default (per-session/per-profile
// isolation; memory: feedback_feature_scoping_and_isolation_tests).

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

  testWidgets('connecting a profile with fontSize=20 sizes that session', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Big font',
        host: 'big.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-1',
        fontSize: 20,
      ),
    ]);

    final container = await _pump(tester, store: store, secrets: secrets);

    await tester.tap(
      find.byKey(const Key('profile-tile-big.example:22:alice')),
    );
    await _pumpFrames(tester);

    final id = container.read(sessionsProvider).entries.first.id;
    expect(
      container.read(sessionFontSizeProvider(id)),
      20,
      reason: 'session must open at the profile\'s persisted font size',
    );
  });

  testWidgets(
    'a second session WITHOUT a profile fontSize stays default (isolation)',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await secrets.write('vault-2', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Big',
          host: 'big.example',
          port: 22,
          username: 'alice',
          authType: 'password',
          vaultId: 'vault-1',
          fontSize: 24,
        ),
        SavedProfile(
          title: 'Plain',
          host: 'plain.example',
          port: 22,
          username: 'bob',
          authType: 'password',
          vaultId: 'vault-2',
          // no fontSize
        ),
      ]);

      final container = await _pump(tester, store: store, secrets: secrets);

      await tester.tap(
        find.byKey(const Key('profile-tile-big.example:22:alice')),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const Key('profile-tile-plain.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 2);
      final big = entries.firstWhere((e) => e.host == 'big.example');
      final plain = entries.firstWhere((e) => e.host == 'plain.example');

      expect(container.read(sessionFontSizeProvider(big.id)), 24);
      expect(
        container.read(sessionFontSizeProvider(plain.id)),
        fontSizeDefault,
        reason: 'a profile without a font size must not inherit the big one',
      );
    },
  );

  testWidgets('a profile with no fontSize opens at the default', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Default',
        host: 'def.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-1',
        // no fontSize
      ),
    ]);

    final container = await _pump(tester, store: store, secrets: secrets);

    await tester.tap(
      find.byKey(const Key('profile-tile-def.example:22:alice')),
    );
    await _pumpFrames(tester);

    final id = container.read(sessionsProvider).entries.first.id;
    expect(container.read(sessionFontSizeProvider(id)), fontSizeDefault);
  });
}
