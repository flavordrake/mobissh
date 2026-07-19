// CRUD tests for the key library (#1088): create-by-import / rename / delete,
// and the security invariant that private material only ever lives in the vault.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
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
}
