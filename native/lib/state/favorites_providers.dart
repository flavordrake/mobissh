// Riverpod provider for per-profile path favorites (#632).
//
// `favoritesStoreProvider` exposes the [FavoritesStore] singleton. The file
// browser reads it via `ref.read` to toggle/list/remove/clear a profile's
// favorited paths. Override in tests with a prefs-injected instance:
// `favoritesStoreProvider.overrideWithValue(FavoritesStore(prefs: ...))`.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/favorites_store.dart';

/// Singleton [FavoritesStore]. Override in tests.
final favoritesStoreProvider = Provider<FavoritesStore>((ref) {
  return FavoritesStore();
});

/// A profile's favorited paths, keyed by `host:port:username` identity (#950).
/// Reactive read used to decide whether a session shows its favorites star and
/// to drive any UI that reflects the set. shared_preferences isn't reactive, so
/// mutations (toggle/remove/clear) must `ref.invalidate(profileFavoritesProvider(key))`
/// to refresh watchers — the file browser does this via `_refreshFavorites` and
/// the session-menu sheet via its `onChanged` callback.
final profileFavoritesProvider =
    FutureProvider.family<List<PathFavorite>, String>((ref, profileKey) async {
      return ref.read(favoritesStoreProvider).favoritesFor(profileKey);
    });
