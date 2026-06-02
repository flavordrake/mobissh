// #679 — connecting from a profile seeds its persisted font FAMILY into THAT
// session (mirrors #640 per-profile font size + #613 per-profile theme). A
// profile whose fontFamily is 'FiraCode' must set the NEW session's per-session
// font family to 'FiraCode' — keyed by the session id, NOT global. A second
// session connected from a profile WITHOUT a fontFamily stays the default face
// (per-session/per-profile isolation; memory:
// feedback_feature_scoping_and_isolation_tests).

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
      child: const MaterialApp(home: Scaffold(body: ConnectForm())),
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

  testWidgets('connecting a profile with fontFamily=FiraCode applies it', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Fira',
        host: 'fira.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-1',
        fontFamily: 'FiraCode',
      ),
    ]);

    final container = await _pump(tester, store: store, secrets: secrets);

    await tester.tap(
      find.byKey(const Key('profile-tile-fira.example:22:alice')),
    );
    await _pumpFrames(tester);

    final id = container.read(sessionsProvider).entries.first.id;
    expect(
      container.read(sessionFontFamilyProvider(id)),
      'FiraCode',
      reason: 'session must open at the profile\'s persisted font family',
    );
  });

  testWidgets(
    'a second session WITHOUT a profile fontFamily stays default (isolation)',
    (tester) async {
      final store = ProfilesStore();
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
      await secrets.write('vault-2', <String, Object?>{'password': 'pw'});
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Cascadia',
          host: 'casc.example',
          port: 22,
          username: 'alice',
          authType: 'password',
          vaultId: 'vault-1',
          fontFamily: 'CascadiaCode',
        ),
        SavedProfile(
          title: 'Plain',
          host: 'plain.example',
          port: 22,
          username: 'bob',
          authType: 'password',
          vaultId: 'vault-2',
          // no fontFamily
        ),
      ]);

      final container = await _pump(tester, store: store, secrets: secrets);

      await tester.tap(
        find.byKey(const Key('profile-tile-casc.example:22:alice')),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const Key('profile-tile-plain.example:22:bob')),
      );
      await _pumpFrames(tester);

      final entries = container.read(sessionsProvider).entries;
      expect(entries.length, 2);
      final casc = entries.firstWhere((e) => e.host == 'casc.example');
      final plain = entries.firstWhere((e) => e.host == 'plain.example');

      expect(
        container.read(sessionFontFamilyProvider(casc.id)),
        'CascadiaCode',
      );
      expect(
        container.read(sessionFontFamilyProvider(plain.id)),
        fontFamilyDefault,
        reason: 'a profile without a font family must not inherit the other',
      );
    },
  );

  testWidgets('a profile with no fontFamily opens at the default face', (
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
        // no fontFamily
      ),
    ]);

    final container = await _pump(tester, store: store, secrets: secrets);

    await tester.tap(
      find.byKey(const Key('profile-tile-def.example:22:alice')),
    );
    await _pumpFrames(tester);

    final id = container.read(sessionsProvider).entries.first.id;
    expect(container.read(sessionFontFamilyProvider(id)), fontFamilyDefault);
  });
}
