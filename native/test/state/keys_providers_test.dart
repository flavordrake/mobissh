// CRUD tests for the key library (#1088): create-by-import / rename / delete,
// and the security invariant that private material only ever lives in the vault.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  ProviderContainer makeContainer(SecretsStore secrets) {
    final c = ProviderContainer(
      overrides: [secretsStoreProvider.overrideWithValue(secrets)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('import writes the PEM to the vault; metadata carries no secret', () async {
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final c = makeContainer(secrets);
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END-----';
    final key = await c
        .read(keysManagerProvider)
        .importFromPem(name: 'work', pem: pem, passphrase: 'pp');

    final stored = await secrets.read(key.vaultId);
    expect(stored?['data'], pem);
    expect(stored?['passphrase'], 'pp');

    final list = await c.read(keysStoreProvider).load();
    expect(list.map((k) => k.id), [key.id]);
    expect(list.single.name, 'work');
    // SECURITY: the private key must never appear in the metadata store.
    expect(list.single.toJson().toString(), isNot(contains('OPENSSH')));
    expect(list.single.toJson().toString(), isNot(contains('pp')));
  });

  test('rename updates metadata only', () async {
    final c = makeContainer(SecretsStore(backend: InMemorySecretsBackend()));
    final mgr = c.read(keysManagerProvider);
    final key = await mgr.importFromPem(name: 'old', pem: 'x');
    await mgr.rename(key.id, 'new');
    expect((await c.read(keysStoreProvider).load()).single.name, 'new');
  });

  test('delete removes BOTH the vault blob and the metadata', () async {
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final c = makeContainer(secrets);
    final mgr = c.read(keysManagerProvider);
    final key = await mgr.importFromPem(name: 'k', pem: 'x');
    expect(await secrets.read(key.vaultId), isNotNull);

    await mgr.delete(key.id);
    expect(await secrets.read(key.vaultId), isNull);
    expect(await c.read(keysStoreProvider).load(), isEmpty);
  });

  test('empty name falls back; rename ignores a blank name', () async {
    final c = makeContainer(SecretsStore(backend: InMemorySecretsBackend()));
    final mgr = c.read(keysManagerProvider);
    final key = await mgr.importFromPem(name: '   ', pem: 'x');
    expect(key.name, 'Imported key');
    await mgr.rename(key.id, '   ');
    expect((await c.read(keysStoreProvider).load()).single.name, 'Imported key');
  });

  group('adoptFromProfiles (#1088 migration)', () {
    Future<ProviderContainer> withProfiles(List<SavedProfile> profiles) async {
      final store = ProfilesStore();
      await store.save(profiles);
      final c = ProviderContainer(overrides: [
        secretsStoreProvider
            .overrideWithValue(SecretsStore(backend: InMemorySecretsBackend())),
        profilesStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('adopts each distinct profile key IN PLACE, named from the profile',
        () async {
      final c = await withProfiles([
        SavedProfile(
          title: 'fd-dev',
          host: 'fd',
          port: 22,
          username: 'me',
          authType: 'key',
          keyVaultId: 'profile-key-fd:22:me',
        ),
        SavedProfile(
          title: 'NV-dev',
          host: 'nv',
          port: 22,
          username: 'me',
          authType: 'key',
          keyVaultId: 'profile-key-nv:22:me',
        ),
        SavedProfile(
          title: 'pw',
          host: 'p',
          port: 22,
          username: 'me',
          authType: 'password',
        ),
      ]);
      final adopted = await c.read(keysManagerProvider).adoptFromProfiles();
      expect(adopted, 2);
      final lib = await c.read(keysStoreProvider).load();
      expect(lib.map((k) => k.name), containsAll(['fd-dev', 'NV-dev']));
      // Adopted keys point at the ORIGINAL vault ids — no re-keying.
      expect(lib.map((k) => k.vaultId),
          containsAll(['profile-key-fd:22:me', 'profile-key-nv:22:me']));
    });

    test('is idempotent — a second run adopts nothing', () async {
      final c = await withProfiles([
        SavedProfile(
          title: 'fd-dev',
          host: 'fd',
          port: 22,
          username: 'me',
          authType: 'key',
          keyVaultId: 'profile-key-fd:22:me',
        ),
      ]);
      final mgr = c.read(keysManagerProvider);
      expect(await mgr.adoptFromProfiles(), 1);
      expect(await mgr.adoptFromProfiles(), 0);
      expect((await c.read(keysStoreProvider).load()).length, 1);
    });

    test('two profiles sharing one key adopt it once', () async {
      final c = await withProfiles([
        SavedProfile(
          title: 'a',
          host: 'a',
          port: 22,
          username: 'me',
          authType: 'key',
          keyVaultId: 'profile-key-shared',
        ),
        SavedProfile(
          title: 'b',
          host: 'b',
          port: 22,
          username: 'me',
          authType: 'key',
          keyVaultId: 'profile-key-shared',
        ),
      ]);
      expect(await c.read(keysManagerProvider).adoptFromProfiles(), 1);
    });
  });
}
