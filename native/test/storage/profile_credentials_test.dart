// Tests for [loadProfileCredentials] (#519).
//
// Covers the connect-path load of decrypted secrets from a [SecretsStore]
// for both the `password`-auth and `key`-auth profile shapes.
//
// Shape contract (mirrors the PWA — see src/modules/profiles.ts:450-493 and
// src/modules/connection.ts:498-507):
//
//   vault.encrypted[vaultId]    → { password?, privateKey?, passphrase? }
//   vault.encrypted[keyVaultId] → { data: <PEM>, passphrase? }
//
// The `data` field on a keyVaultId-keyed entry holds the PEM-encoded private
// key. The keyVaultId entry's passphrase wins over the password entry's
// passphrase for a `key`-auth profile (per PWA precedence).
//
// Why these tests exist: prior to #519 the native importer decrypted and
// persisted ALL vault entries correctly, but the connect-form prefill only
// loaded `profile.vaultId` and never consulted `profile.keyVaultId`. Result:
// the key bytes were sitting in flutter_secure_storage but never reached
// dartssh2. These tests lock the load behavior in.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('loadProfileCredentials — password auth', () {
    test('loads password + passphrase from vaultId entry', () async {
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('v-pw', <String, Object?>{
        'password': 'hunter2',
        'passphrase': 'pp',
      });

      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'password', vaultId: 'v-pw',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.password, 'hunter2');
      expect(creds.passphrase, 'pp');
      expect(creds.privateKey, isNull);
    });

    test('returns empty creds when no vaultId is set', () async {
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'password',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.password, isNull);
      expect(creds.privateKey, isNull);
      expect(creds.passphrase, isNull);
    });
  });

  group('loadProfileCredentials — key auth', () {
    test('loads private key bytes + passphrase from keyVaultId entry',
        () async {
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n'
          '-----END OPENSSH PRIVATE KEY-----';
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('v-key', <String, Object?>{
        'data': pem,
        'passphrase': 'keypass',
      });

      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'key', keyVaultId: 'v-key',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.privateKey, pem,
          reason: 'PWA stores the PEM under `data` for keyVaultId entries');
      expect(creds.passphrase, 'keypass');
      expect(creds.password, isNull);
    });

    test('loads key even when vaultId is also present', () async {
      // A key-auth profile may carry both a vaultId (legacy / host-shared)
      // and a keyVaultId. The key MUST come from keyVaultId, not vaultId.
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nzzz\n'
          '-----END OPENSSH PRIVATE KEY-----';
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('v-shared', <String, Object?>{
        'password': 'leftover-password',
      });
      await secrets.write('v-key', <String, Object?>{
        'data': pem,
        'passphrase': 'kp',
      });

      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'key', vaultId: 'v-shared', keyVaultId: 'v-key',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.privateKey, pem);
      expect(creds.passphrase, 'kp',
          reason: 'keyVaultId passphrase wins over vaultId passphrase');
    });

    test('keyVaultId passphrase wins over vaultId passphrase', () async {
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('v-shared', <String, Object?>{
        'password': 'pw',
        'passphrase': 'old-pp',
      });
      await secrets.write('v-key', <String, Object?>{
        'data': 'PEM',
        'passphrase': 'new-pp',
      });

      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'key', vaultId: 'v-shared', keyVaultId: 'v-key',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.passphrase, 'new-pp');
    });

    test('returns empty creds when keyVaultId entry is missing', () async {
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'key', keyVaultId: 'v-missing',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.password, isNull);
      expect(creds.privateKey, isNull);
      expect(creds.passphrase, isNull);
    });

    test('falls back to legacy `privateKey` field on keyVaultId entry',
        () async {
      // Belt-and-braces: if someone wrote the key under `privateKey` instead
      // of `data` (e.g. an older importer), the load path should still find
      // it. PWA's canonical shape uses `data`, but a forgiving reader avoids
      // breakage on the import path.
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write('v-legacy', <String, Object?>{
        'privateKey': 'legacy-pem',
      });

      final profile = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        authType: 'key', keyVaultId: 'v-legacy',
      );

      final creds = await loadProfileCredentials(secrets, profile);

      expect(creds.privateKey, 'legacy-pem');
    });
  });
}
