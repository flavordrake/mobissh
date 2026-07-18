// Reusable profile-scoped favorites bottom sheet (#632, #950).
//
// Extracted from the file browser so favorites can be opened from MORE than the
// browser's app-bar star — the session menu surfaces a per-session favorites
// star (#950) that opens this same sheet scoped to that session's profile.
//
// The sheet is presentation + actions only; it owns NO state. It reads the
// profile's favorites FRESH from [FavoritesStore] each open, removes/clears
// through the store, and routes a tapped favorite back to the caller via
// [onNavigate] (the browser navigates in place; the session menu opens the file
// browser at that path). [onChanged] fires after any mutation so the caller can
// refresh its own view (the browser's star, the session star's provider).
//
// Widget keys are identical to the browser's original menu (favorites-list,
// favorite-item-<path>, favorites-clear-all, favorites-empty) so existing
// favorites tests keep addressing them.

import 'package:flutter/material.dart';

import '../storage/favorites_store.dart';
import '../util/favorites_prefix.dart';

/// Opens the favorites sheet for [profileKey]. Tapping a favorite pops the sheet
/// then calls [onNavigate] with its path; long-press removes it; "Clear all"
/// empties the set. [onChanged] runs after every mutation (remove/clear).
Future<void> showFavoritesMenu(
  BuildContext context, {
  required FavoritesStore store,
  required String profileKey,
  required void Function(String path) onNavigate,
  VoidCallback? onChanged,
}) async {
  var favs = await store.favoritesFor(profileKey);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          // Collapse the shared path prefix of UNLABELED favorites (#493) so
          // the divergent leaf is scannable. Labeled favorites keep their
          // label (they fall through to f.display below).
          final unlabeledPaths = [
            for (final f in favs)
              if (f.label == null || f.label!.isEmpty) f.path,
          ];
          final collapsed = collapsePrefix(unlabeledPaths);
          final collapsedByPath = {
            for (var i = 0; i < unlabeledPaths.length; i++)
              unlabeledPaths[i]: collapsed[i],
          };
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.star),
                  title: const Text('Favorites'),
                  trailing: TextButton(
                    key: const Key('favorites-clear-all'),
                    onPressed: favs.isEmpty
                        ? null
                        : () async {
                            await store.clear(profileKey);
                            favs = const [];
                            onChanged?.call();
                            setSheetState(() {});
                          },
                    child: const Text('Clear all'),
                  ),
                ),
                const Divider(height: 1),
                if (favs.isEmpty)
                  const Padding(
                    key: Key('favorites-empty'),
                    padding: EdgeInsets.all(24),
                    child: Text('No favorites yet'),
                  )
                else
                  Flexible(
                    child: ListView(
                      key: const Key('favorites-list'),
                      shrinkWrap: true,
                      children: [
                        for (final f in favs)
                          ListTile(
                            key: Key('favorite-item-${f.path}'),
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(
                              collapsedByPath[f.path] ?? f.display,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: (f.label != null && f.label!.isNotEmpty)
                                ? Text(f.path, overflow: TextOverflow.ellipsis)
                                : null,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              onNavigate(f.path);
                            },
                            // Long-press a favorite = REMOVE it (#632 bullet 4).
                            onLongPress: () async {
                              await store.remove(profileKey, f.path);
                              favs = await store.favoritesFor(profileKey);
                              onChanged?.call();
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}
