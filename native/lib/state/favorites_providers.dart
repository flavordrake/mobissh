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
