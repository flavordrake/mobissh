// Widget tests for the SSH key-library manager (#1088 Slice 1b): the screen
// lists library keys, Add imports one, Rename and Delete work, and Delete warns
// when a profile references the key. Private material is never rendered.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/keys_screen.dart';

Future<void> _pump(
  WidgetTester tester, {
  required KeysStore keysStore,
  required SecretsStore secrets,
  required ProfilesStore profilesStore,
}) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keysStoreProvider.overrideWithValue(keysStore),
        secretsStoreProvider.overrideWithValue(secrets),
        profilesStoreProvider.overrideWithValue(profilesStore),
      ],
      child: const MaterialApp(home: KeysScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('lists library keys by name; no private material shown', (
    tester,
  ) async {
    final keysStore = KeysStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END-----';
    final key = const SavedKey(
      id: 'k1',
      name: 'work laptop',
      algorithm: 'ed25519',
      createdAtMs: 1,
    );
    await secrets.write(key.vaultId, <String, Object?>{'data': pem});
    await keysStore.upsert(key);

    await _pump(
      tester,
      keysStore: keysStore,
      secrets: secrets,
      profilesStore: ProfilesStore(),
    );

    expect(find.text('work laptop'), findsOneWidget);
    expect(find.textContaining('ed25519'), findsOneWidget);
    // SECURITY: the private key blob must never render.
    expect(find.textContaining('OPENSSH'), findsNothing);
    expect(find.textContaining('secret'), findsNothing);
  });

  testWidgets('Add imports a key into the store and the vault', (tester) async {
    final keysStore = KeysStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await _pump(
      tester,
      keysStore: keysStore,
      secrets: secrets,
      profilesStore: ProfilesStore(),
    );

    expect(find.byKey(const ValueKey('keys-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('keys-add-fab')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('keys-add-name')),
      'deploy key',
    );
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END-----';
    await tester.enterText(find.byKey(const ValueKey('keys-add-pem')), pem);
    await tester.tap(find.byKey(const ValueKey('keys-add-save')));
    await tester.pumpAndSettle();

    final keys = await keysStore.load();
    expect(keys.map((k) => k.name), ['deploy key']);
    // The PEM went to the vault, not the metadata store.
    final stored = await secrets.read(keys.single.vaultId);
    expect(stored?['data'], pem);
    expect(keys.single.toJson().toString(), isNot(contains('OPENSSH')));
    // The new key shows in the list.
    expect(find.text('deploy key'), findsOneWidget);
  });

  testWidgets('Rename updates the key name', (tester) async {
    final keysStore = KeysStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final key = const SavedKey(id: 'k1', name: 'old', createdAtMs: 1);
    await secrets.write(key.vaultId, <String, Object?>{'data': 'x'});
    await keysStore.upsert(key);
    await _pump(
      tester,
      keysStore: keysStore,
      secrets: secrets,
      profilesStore: ProfilesStore(),
    );

    await tester.tap(find.byKey(const ValueKey('keys-row-menu-k1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('keys-rename-field')),
      'new name',
    );
    await tester.tap(find.byKey(const ValueKey('keys-rename-save')));
    await tester.pumpAndSettle();

    expect((await keysStore.load()).single.name, 'new name');
    expect(find.text('new name'), findsOneWidget);
  });

  testWidgets('Delete removes the key and its vault blob', (tester) async {
    final keysStore = KeysStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final key = const SavedKey(id: 'k1', name: 'gone', createdAtMs: 1);
    await secrets.write(key.vaultId, <String, Object?>{'data': 'x'});
    await keysStore.upsert(key);
    await _pump(
      tester,
      keysStore: keysStore,
      secrets: secrets,
      profilesStore: ProfilesStore(),
    );

    await tester.tap(find.byKey(const ValueKey('keys-row-menu-k1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    // No profile references it → the warning names no profiles.
    expect(find.textContaining('profile'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('keys-delete-confirm')));
    await tester.pumpAndSettle();

    expect(await keysStore.load(), isEmpty);
    expect(await secrets.read(key.vaultId), isNull);
  });

  testWidgets('Delete warns when a profile references the key', (tester) async {
    final keysStore = KeysStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final key = const SavedKey(id: 'k1', name: 'shared', createdAtMs: 1);
    await secrets.write(key.vaultId, <String, Object?>{'data': 'x'});
    await keysStore.upsert(key);
    final profilesStore = ProfilesStore();
    await profilesStore.save(<SavedProfile>[
      SavedProfile(
        title: 'deploy@prod',
        host: 'prod',
        port: 22,
        username: 'deploy',
        authType: 'key',
        keyVaultId: key.vaultId,
      ),
    ]);
    await _pump(
      tester,
      keysStore: keysStore,
      secrets: secrets,
      profilesStore: profilesStore,
    );

    await tester.tap(find.byKey(const ValueKey('keys-row-menu-k1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Used by 1 profile'), findsOneWidget);
  });
}
