// Key-library CRUD coordination (#1088). Ties the NON-secret metadata store
// ([KeysStore]) to the encrypted vault ([SecretsStore]) so a key's private
// material only ever lives in the vault. UI reads [savedKeysProvider]; mutations
// go through [keysManagerProvider] (create-by-import / rename / delete), which
// invalidates the list after each change.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/keys_store.dart';
import 'profiles_providers.dart'; // secretsStoreProvider

/// Singleton [KeysStore] (metadata). Override in tests with a seeded prefs.
final keysStoreProvider = Provider<KeysStore>((ref) => KeysStore());

/// The key library, name-sorted. Invalidated by [KeysManager] after a mutation.
final savedKeysProvider = FutureProvider<List<SavedKey>>((ref) async {
  final keys = await ref.watch(keysStoreProvider).load();
  keys.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return keys;
});

/// CRUD across the metadata store + the vault. Private bytes are written/deleted
/// ONLY through [SecretsStore]; metadata never carries them.
class KeysManager {
  KeysManager(this._ref, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Ref _ref;
  final DateTime Function() _now;

  /// Import a pasted private key (PEM/OpenSSH) as a named library key. The PEM
  /// (+ optional passphrase) is written to the vault; only metadata is stored in
  /// prefs. Returns the created [SavedKey].
  Future<SavedKey> importFromPem({
    required String name,
    required String pem,
    String? passphrase,
    String? algorithm,
  }) async {
    final ts = _now();
    final id = 'k${ts.microsecondsSinceEpoch}';
    final key = SavedKey(
      id: id,
      name: name.trim().isEmpty ? 'Imported key' : name.trim(),
      algorithm: algorithm,
      createdAtMs: ts.millisecondsSinceEpoch,
    );
    await _ref.read(secretsStoreProvider).write(key.vaultId, <String, Object?>{
      'data': pem,
      if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
    });
    await _ref.read(keysStoreProvider).upsert(key);
    _ref.invalidate(savedKeysProvider);
    return key;
  }

  /// Rename a library key (metadata only). No-op for an unknown id or a
  /// whitespace-only name.
  Future<void> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final store = _ref.read(keysStoreProvider);
    SavedKey? existing;
    for (final k in await store.load()) {
      if (k.id == id) {
        existing = k;
        break;
      }
    }
    if (existing == null) return;
    await store.upsert(existing.copyWith(name: trimmed));
    _ref.invalidate(savedKeysProvider);
  }

  /// Delete a library key — removes BOTH the vault blob and the metadata. The
  /// caller is responsible for warning when profiles still reference it (their
  /// `keyVaultId` will dangle until re-attached).
  Future<void> delete(String id) async {
    await _ref.read(secretsStoreProvider).delete(keyVaultIdFor(id));
    await _ref.read(keysStoreProvider).remove(id);
    _ref.invalidate(savedKeysProvider);
  }
}

final keysManagerProvider = Provider<KeysManager>((ref) => KeysManager(ref));
