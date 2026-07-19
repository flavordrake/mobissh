// Unit tests for the SSH key-library metadata store (#1088).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SavedKey', () {
    test('vaultId is stable and prefixed', () {
      const k = SavedKey(id: 'abc', name: 'work');
      expect(k.vaultId, 'key-abc');
      expect(keyVaultIdFor('abc'), 'key-abc');
    });

    test('toJson/fromJson round-trips', () {
      const k = SavedKey(
        id: 'k1',
        name: 'deploy key',
        algorithm: 'ed25519',
        publicKey: 'ssh-ed25519 AAAA deploy',
        fingerprint: 'SHA256:zzz',
        createdAtMs: 1234,
      );
      final back = SavedKey.fromJson(k.toJson());
      expect(back, k);
    });

    test('fromJson rejects a missing id or name', () {
      expect(
        () => SavedKey.fromJson(<String, dynamic>{'name': 'x'}),
        throwsFormatException,
      );
      expect(
        () => SavedKey.fromJson(<String, dynamic>{'id': 'x'}),
        throwsFormatException,
      );
    });

    test('toJson never carries private material (only metadata keys)', () {
      const k = SavedKey(id: 'k1', name: 'n');
      expect(k.toJson().keys, isNot(contains('data')));
      expect(k.toJson().keys, isNot(contains('passphrase')));
    });
  });

  group('KeysStore', () {
    test('load is empty with nothing stored', () async {
      expect(await KeysStore().load(), isEmpty);
    });

    test('upsert adds then replaces by id; load reads back', () async {
      final store = KeysStore();
      await store.upsert(const SavedKey(id: 'k1', name: 'first'));
      await store.upsert(const SavedKey(id: 'k2', name: 'second'));
      expect((await store.load()).map((k) => k.id), containsAll(['k1', 'k2']));

      await store.upsert(const SavedKey(id: 'k1', name: 'renamed'));
      final list = await store.load();
      expect(list.length, 2);
      expect(list.firstWhere((k) => k.id == 'k1').name, 'renamed');
    });

    test('remove drops one entry, no-op for unknown', () async {
      final store = KeysStore();
      await store.upsert(const SavedKey(id: 'k1', name: 'a'));
      await store.upsert(const SavedKey(id: 'k2', name: 'b'));
      await store.remove('k1');
      expect((await store.load()).map((k) => k.id), ['k2']);
      await store.remove('nope'); // no throw
      expect((await store.load()).length, 1);
    });

    test('malformed storage → empty (corrupt resilience)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        keysPrefsKey: 'not json',
      });
      expect(await KeysStore().load(), isEmpty);
    });

    test('a corrupt entry is skipped, good ones kept', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        keysPrefsKey: '[{"id":"ok","name":"good"},{"name":"no-id"}]',
      });
      final list = await KeysStore().load();
      expect(list.map((k) => k.id), ['ok']);
    });
  });
}
