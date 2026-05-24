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
