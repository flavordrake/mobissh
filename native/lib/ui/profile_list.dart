// Saved-profile list rendered above the ConnectForm (#501).
//
// Empty-state hint nudges the user to import from the PWA. Each row is a tap
// target that pre-fills the parent form via the [onSelect] callback. The
// parent owns mutation — this widget is purely presentation + selection.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/profiles_providers.dart';
import '../storage/profiles_store.dart';

typedef ProfileSelectCallback = void Function(SavedProfile profile);

class ProfileList extends ConsumerWidget {
  const ProfileList({super.key, required this.onSelect});

  /// Fired when the user taps a profile row. Parent populates ConnectForm
  /// fields with the chosen profile's metadata (host/port/username).
  final ProfileSelectCallback onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(savedProfilesProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(child: SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2),
        )),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Profiles error: $e',
            style: const TextStyle(color: Colors.redAccent)),
      ),
      data: (profiles) {
        if (profiles.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No saved profiles. Import from PWA to skip retyping.',
              key: Key('profile-list-empty'),
              style: TextStyle(color: Colors.grey),
            ),
          );
        }
        return Column(
          key: const Key('profile-list-populated'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Saved Profiles',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            // Constrain so a giant list doesn't push the form off-screen.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: profiles.length,
                itemBuilder: (context, i) {
                  final p = profiles[i];
                  return _ProfileTile(
                    profile: p,
                    onTap: () => onSelect(p),
                  );
                },
              ),
            ),
            const Divider(),
          ],
        );
      },
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.profile, required this.onTap});

  final SavedProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(profile.color);
    return ListTile(
      key: Key('profile-tile-${profile.identityKey}'),
      dense: true,
      leading: CircleAvatar(
        backgroundColor: color ?? Theme.of(context).colorScheme.primary,
        radius: 8,
      ),
      title: Text(profile.title, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${profile.username}@${profile.host}:${profile.port}',
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}

/// Parse a hex color string like "#ff8800" into a Color. Returns null when
/// the input doesn't match — caller falls back to the theme primary.
Color? _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  var raw = hex.trim();
  if (raw.startsWith('#')) raw = raw.substring(1);
  if (raw.length == 6) raw = 'FF$raw';
  if (raw.length != 8) return null;
  final v = int.tryParse(raw, radix: 16);
  if (v == null) return null;
  return Color(v);
}
