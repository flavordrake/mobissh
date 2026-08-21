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

  /// Re-enter the PRIVATE material for an EXISTING library key, writing to the
  /// key's SAME vault id — so every profile attached via that `keyVaultId`
  /// heals at once, no re-attaching. The phone-migration recovery path (#1121):
  /// key METADATA survives an Android migration in SharedPreferences, but the
  /// Keystore-encrypted material does not; this restores it in place, where
  /// [importFromPem] would mint a NEW key the profiles don't point at.
  /// Payload shape matches [importFromPem] / `loadProfileCredentials`
  /// (`{data, passphrase?}`). Throws [ArgumentError] for an unknown id.
  Future<void> reenterPem(
    String id, {
    required String pem,
    String? passphrase,
  }) async {
    SavedKey? existing;
    for (final k in await _ref.read(keysStoreProvider).load()) {
      if (k.id == id) {
        existing = k;
        break;
      }
    }
    if (existing == null) {
      throw ArgumentError.value(id, 'id', 'unknown library key');
    }
    await _ref.read(secretsStoreProvider).write(existing.vaultId, <String, Object?>{
      'data': pem,
      if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
    });
    _ref.invalidate(savedKeysProvider);
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

  /// Adopt pre-existing per-profile keys into the library (#1088): for each
  /// distinct `keyVaultId` referenced by a saved profile that isn't already a
  /// library key, create a [SavedKey] pointing at that SAME vault id IN PLACE —
  /// no re-keying, no vault movement, the private material stays put. Named from
  /// the owning profile's title. Idempotent (dedups against existing library
  /// vault ids and within the run), so it's safe to call on every Keys-screen /
  /// picker open. Returns how many keys were newly adopted.
  Future<int> adoptFromProfiles() async {
    final profiles = await _ref.read(profilesStoreProvider).load();
    final store = _ref.read(keysStoreProvider);
    final known = (await store.load()).map((k) => k.vaultId).toSet();
    final seen = <String>{};
    final ts = _now();
    var adopted = 0;
    for (final p in profiles) {
      final vid = p.keyVaultId;
      if (vid == null || vid.isEmpty) continue;
      if (known.contains(vid) || !seen.add(vid)) continue;
      await store.upsert(SavedKey(
        id: 'k${ts.microsecondsSinceEpoch}_$adopted',
        name: p.title.trim().isEmpty ? vid : p.title.trim(),
        vaultId: vid,
        createdAtMs: ts.millisecondsSinceEpoch,
      ));
      adopted++;
    }
    if (adopted > 0) _ref.invalidate(savedKeysProvider);
    return adopted;
  }

  /// Delete a library key — removes BOTH the vault blob and the metadata. The
  /// caller is responsible for warning when profiles still reference it (their
  /// `keyVaultId` will dangle until re-attached).
  ///
  /// Resolves the vault id the same way the write path does (`key.vaultId`,
  /// #1109c): an ADOPTED key's material lives at the profile's original
  /// `keyVaultId`, NOT the `key-<id>` default — deleting the default would be a
  /// silent no-op that leaks the private key and leaves the profile still
  /// authenticating. Falls back to `keyVaultIdFor(id)` for a metadata-only stray
  /// with no matching [SavedKey].
  Future<void> delete(String id) async {
    final store = _ref.read(keysStoreProvider);
    String vaultId = keyVaultIdFor(id);
    for (final k in await store.load()) {
      if (k.id == id) {
        vaultId = k.vaultId;
        break;
      }
    }
    await _ref.read(secretsStoreProvider).delete(vaultId);
    await store.remove(id);
    _ref.invalidate(savedKeysProvider);
  }
}

final keysManagerProvider = Provider<KeysManager>((ref) => KeysManager(ref));
