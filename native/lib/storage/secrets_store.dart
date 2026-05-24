// Native secrets store (#510).
//
// Wraps `flutter_secure_storage` for per-vaultId secret persistence.
// The PWA's `vault.encrypted[vaultId]` map is decrypted on import and the
// plaintext per-vault JSON gets written here, keyed by vaultId. Storage is
// Android-Keystore-backed at rest; the platform handles re-encryption.
//
// Tests inject a [SecretsBackend] fake — `flutter_secure_storage` itself
// uses a platform channel that is not available in `flutter_test`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage namespace prefix. Bumping this string forces all callers to
/// re-import their vault; do NOT bump to fix cache issues (per CLAUDE.md
/// localStorage policy).
const String kSecretsKeyPrefix = 'mobissh.secret.v1.';

/// Pluggable backing store. The production implementation forwards to
/// [FlutterSecureStorage]; tests inject [InMemorySecretsBackend].
abstract class SecretsBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// Production backend: Android Keystore-backed via flutter_secure_storage.
class FlutterSecureStorageBackend implements SecretsBackend {
  FlutterSecureStorageBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// In-memory backend for tests + flutter_test widget runs (no platform
/// channel).
class InMemorySecretsBackend implements SecretsBackend {
  final Map<String, String> _store = <String, String>{};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.from(_store);
}

/// Per-vaultId secrets persistence.
///
/// The secret payload is the same shape the PWA writes: usually
/// `{password, privateKey?, passphrase?}` JSON-encoded. This class does not
/// inspect the shape — callers know their own schema.
class SecretsStore {
  SecretsStore({SecretsBackend? backend})
      : _backend = backend ?? FlutterSecureStorageBackend();

  final SecretsBackend _backend;

  String _keyFor(String vaultId) => '$kSecretsKeyPrefix$vaultId';

  /// Persist a secret payload under [vaultId]. Overwrites any existing value.
  Future<void> write(String vaultId, Map<String, Object?> secret) {
    return _backend.write(_keyFor(vaultId), jsonEncode(secret));
  }

  /// Read the secret payload for [vaultId], or null if not stored.
  Future<Map<String, Object?>?> read(String vaultId) async {
    final raw = await _backend.read(_keyFor(vaultId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Delete the secret for [vaultId]. No-op if not present.
  Future<void> delete(String vaultId) => _backend.delete(_keyFor(vaultId));

  /// List all currently-stored vaultIds. Used by the biometric gate to know
  /// whether any unlock is required at app start.
  Future<Set<String>> listVaultIds() async {
    final all = await _backend.readAll();
    final out = <String>{};
    for (final key in all.keys) {
      if (key.startsWith(kSecretsKeyPrefix)) {
        out.add(key.substring(kSecretsKeyPrefix.length));
      }
    }
    return out;
  }
}
