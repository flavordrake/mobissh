// Tests for SecretsStore resilience against a poisoned backing store (#1118).
//
// After an Android phone migration, backup restores the encrypted
// flutter_secure_storage blobs (SharedPreferences) but NOT the Keystore
// master key. Every backend read then throws a PlatformException. Prior to
// #1118 SecretsStore.read caught only FormatException, so the platform throw
// propagated all the way up to the profile-tap handler and died silently.
//
// Contract locked in here: callers treat read() as "null if absent OR
// unreadable" — a raw platform throw must never escape the store. Same for
// listVaultIds(): a startup/biometric-gate path must not crash on a poisoned
// store.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

/// Backend fake simulating the post-migration Keystore state: the encrypted
/// blobs exist but every decrypting read throws (missing master key).
class ThrowingSecretsBackend implements SecretsBackend {
  @override
  Future<String?> read(String key) async {
    throw PlatformException(
      code: 'BadDecrypt',
      message: 'Failed to decrypt: Keystore key not found',
    );
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<Map<String, String>> readAll() async {
    throw PlatformException(
      code: 'BadDecrypt',
      message: 'Failed to decrypt: Keystore key not found',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecretsStore with a throwing backend (#1118 migration signature)', () {
    test('read() returns null instead of propagating the platform throw',
        () async {
      final secrets = SecretsStore(backend: ThrowingSecretsBackend());

      final result = await secrets.read('vault-1');

      expect(result, isNull,
          reason: 'unreadable must behave like absent — callers treat read() '
              'as "null if absent" and must never see a raw PlatformException');
    });

    test('listVaultIds() returns empty instead of propagating the throw',
        () async {
      final secrets = SecretsStore(backend: ThrowingSecretsBackend());

      final ids = await secrets.listVaultIds();

      expect(ids, isEmpty,
          reason: 'the biometric gate calls this at app start; a poisoned '
              'store must not crash startup');
    });

    test('loadProfileCredentials returns empty creds, does not throw',
        () async {
      final secrets = SecretsStore(backend: ThrowingSecretsBackend());
      final profile = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        authType: 'password',
        vaultId: 'vault-1',
        keyVaultId: 'vault-key',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.isEmpty, isTrue,
          reason: 'the connect path must reach its no-creds fallback (toast + '
              'editor), not die in an unhandled async throw');
    });
  });
}
