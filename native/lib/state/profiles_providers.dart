// Riverpod providers for saved-profile persistence (#501).
//
// `profilesStoreProvider` exposes the [ProfilesStore] singleton.
// `savedProfilesProvider` watches the loaded list; the UI reads it via
// `ref.watch` and refreshes via `ref.invalidate(savedProfilesProvider)`
// after mutating operations (save / import / remove).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/profiles_store.dart';

/// Singleton [ProfilesStore]. Override in tests via
/// `profilesStoreProvider.overrideWithValue(myStore)`.
final profilesStoreProvider = Provider<ProfilesStore>((ref) {
  return ProfilesStore();
});

/// Async-loaded list of saved profiles. UI watches this; invalidate after
/// mutating operations so the watcher re-fetches.
final savedProfilesProvider = FutureProvider<List<SavedProfile>>((ref) async {
  final store = ref.watch(profilesStoreProvider);
  return store.load();
});
