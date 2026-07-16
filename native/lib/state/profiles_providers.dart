// Riverpod providers for saved-profile persistence (#501).
//
// `profilesStoreProvider` exposes the [ProfilesStore] singleton.
// `savedProfilesProvider` watches the loaded list; the UI reads it via
// `ref.watch` and refreshes via `ref.invalidate(savedProfilesProvider)`
// after mutating operations (save / import / remove).
//
// `secretsStoreProvider` exposes the [SecretsStore] singleton (#510). The
// production backing is Android-Keystore via flutter_secure_storage; tests
// override with an in-memory backend.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/profiles_store.dart';
import '../storage/secrets_store.dart';

/// Singleton [ProfilesStore]. Override in tests via
/// `profilesStoreProvider.overrideWithValue(myStore)`.
final profilesStoreProvider = Provider<ProfilesStore>((ref) {
  return ProfilesStore();
});

/// Singleton [SecretsStore] (#510). Override in tests with an
/// `InMemorySecretsBackend`-backed instance.
final secretsStoreProvider = Provider<SecretsStore>((ref) {
  return SecretsStore();
});

/// Async-loaded list of saved profiles. UI watches this; invalidate after
/// mutating operations so the watcher re-fetches.
final savedProfilesProvider = FutureProvider<List<SavedProfile>>((ref) async {
  final store = ref.watch(profilesStoreProvider);
  return store.load();
});

/// A reusable reference to an SSH key already stored in the vault — the
/// [keyVaultId] that addresses the secret plus a human [label] for the picker.
@immutable
class StoredKeyRef {
  const StoredKeyRef({required this.keyVaultId, required this.label});

  /// The vault id the secret lives under. A new/edited profile points its
  /// `keyVaultId` at this to reuse the same key WITHOUT re-pasting the PEM.
  final String keyVaultId;

  /// Display label — the owning profile's title (e.g. `deploy@prod`).
  final String label;

  @override
  bool operator ==(Object other) =>
      other is StoredKeyRef &&
      other.keyVaultId == keyVaultId &&
      other.label == label;

  @override
  int get hashCode => Object.hash(keyVaultId, label);
}

/// The distinct SSH keys already stored across saved profiles — the set a new
/// or edited profile can point at instead of re-pasting the PEM (profile-import
/// goal). Derived from saved profiles that carry a `keyVaultId`, deduped by
/// vault id (first profile wins the label), so the same key shared by several
/// hosts appears once.
final storedKeysProvider = FutureProvider<List<StoredKeyRef>>((ref) async {
  final profiles = await ref.watch(savedProfilesProvider.future);
  final seen = <String>{};
  final out = <StoredKeyRef>[];
  for (final p in profiles) {
    final id = p.keyVaultId;
    if (id == null || id.isEmpty) continue;
    if (!seen.add(id)) continue;
    out.add(StoredKeyRef(keyVaultId: id, label: p.title));
  }
  return out;
});
