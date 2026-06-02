// Saved-profile list rendered above the ConnectForm (#501).
//
// Empty-state hint nudges the user to import from the PWA. Each row is a tap
// target that CONNECTS immediately via [onConnect] (#579 — PWA tap=connect
// parity), and carries an edit-pencil ([onEdit]) opening the profile editor.
// The parent owns mutation — this widget is purely presentation + dispatch.
//
// #660: per-ROW connect affordance. The owner reported (build 'f') that #648's
// modal "Connection failed" AlertDialog blocked the whole list. We mirror the
// PWA (`src/modules/profiles.ts`): each row derives its connect state from the
// SESSION whose `profileKey` matches the profile's `identityKey`:
//   - connecting/authenticating/awaitingHostKey/reconnecting → inline spinner +
//     "Connecting…" ON THE ROW (no modal, no global spinner),
//   - failed → a compact inline error + a RETRY affordance ON THE ROW (NOT a
//     blocking dialog). The full reason stays reachable: tapping the inline
//     error opens a non-blocking detail dialog (explicit, user-initiated).
// The row stays reactive by watching the matching session's proxy state stream.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../storage/profiles_store.dart';

typedef ProfileSelectCallback = void Function(SavedProfile profile);

class ProfileList extends ConsumerWidget {
  const ProfileList({super.key, required this.onConnect, required this.onEdit});

  /// Fired when the user taps a profile row. Parent CONNECTS to the chosen
  /// profile immediately (resolve params + vault creds → addOrActivate →
  /// proxy.connect). This is the #579 tap-to-connect behavior — no separate
  /// Connect tap, no form round-trip. Also used by the row's RETRY affordance
  /// (#660) to re-dispatch the same connection.
  final ProfileSelectCallback onConnect;

  /// Fired when the user taps a row's edit pencil. Parent opens the profile
  /// editor pre-populated from the chosen profile (#579).
  final ProfileSelectCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(savedProfilesProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Profiles error: $e',
          style: const TextStyle(color: Colors.redAccent),
        ),
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
            // #643: the list FILLS the available height instead of a fixed
            // 220px cap that left ~60% of the screen blank below. `Expanded`
            // takes whatever vertical room the parent gives (the chooser places
            // ProfileList in its own Expanded), and the ListView scrolls within
            // that full height when there are more profiles than fit. No
            // `shrinkWrap` — the list gets a bounded height from the Expanded.
            Expanded(
              child: ListView.builder(
                itemCount: profiles.length,
                itemBuilder: (context, i) {
                  final p = profiles[i];
                  return _ProfileTile(
                    profile: p,
                    onTap: () => onConnect(p),
                    onEdit: () => onEdit(p),
                    onRetry: () => onConnect(p),
                  );
                },
              ),
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}

/// One profile row. A [ConsumerWidget] so it can watch the session collection
/// and reflect the matching session's live connect state inline (#660).
class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({
    required this.profile,
    required this.onTap,
    required this.onEdit,
    required this.onRetry,
  });

  final SavedProfile profile;

  /// Row tap → connect (#579).
  final VoidCallback onTap;

  /// Pencil tap → open the profile editor (#579).
  final VoidCallback onEdit;

  /// Inline-error retry tap → re-dispatch connect for this profile (#660).
  final VoidCallback onRetry;

  /// Find the session (if any) whose `profileKey` matches this profile's
  /// `identityKey` (`host:port:username`). Mirrors the PWA's per-profile
  /// session match (`src/modules/profiles.ts`).
  SessionEntry? _matchingSession(WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider).entries;
    final key = profile.identityKey;
    for (final e in sessions) {
      if (e.profileKey == key) return e;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = _parseColor(profile.color);
    final entry = _matchingSession(ref);

    return ListTile(
      key: Key('profile-tile-${profile.identityKey}'),
      dense: true,
      leading: CircleAvatar(
        backgroundColor: color ?? Theme.of(context).colorScheme.primary,
        radius: 8,
      ),
      title: Text(profile.title, overflow: TextOverflow.ellipsis),
      // The subtitle carries the host line PLUS — when a matching session is
      // mid-connect or failed — an inline connect affordance (#660). It stays
      // reactive by streaming the matching session's proxy state.
      subtitle: _ProfileSubtitle(
        profile: profile,
        entry: entry,
        onRetry: onRetry,
      ),
      // Edit pencil opens the editor; the row tap (onTap) connects. Keeping
      // the pencil as a distinct trailing target means a row tap never
      // accidentally edits — it always connects (PWA parity).
      trailing: IconButton(
        key: Key('profile-edit-${profile.identityKey}'),
        icon: const Icon(Icons.edit_outlined),
        tooltip: 'Edit profile',
        onPressed: onEdit,
      ),
      onTap: onTap,
    );
  }
}

/// The row subtitle: the `user@host:port` line, with an inline connect-state
/// affordance appended when a matching session is connecting or failed (#660).
///
/// Reactive: when there's a matching [entry], we stream its proxy state so the
/// row repaints as the session moves connecting → failed / connected. When
/// there's no session (or the session is in a steady non-connect state), we
/// render just the host line.
class _ProfileSubtitle extends StatelessWidget {
  const _ProfileSubtitle({
    required this.profile,
    required this.entry,
    required this.onRetry,
  });

  final SavedProfile profile;
  final SessionEntry? entry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hostLine = Text(
      '${profile.username}@${profile.host}:${profile.port}',
      overflow: TextOverflow.ellipsis,
    );

    final e = entry;
    if (e == null) return hostLine;

    return StreamBuilder<SshSessionData>(
      stream: e.proxy.stream,
      initialData: e.proxy.data,
      builder: (context, snapshot) {
        final state = snapshot.data?.state ?? SshSessionState.idle;
        final affordance = _affordanceFor(context, state, snapshot.data?.error);
        if (affordance == null) return hostLine;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [hostLine, const SizedBox(height: 4), affordance],
        );
      },
    );
  }

  /// Build the inline affordance for [state], or null for steady states that
  /// need no connect indicator (idle / connected / disconnected / soft).
  Widget? _affordanceFor(
    BuildContext context,
    SshSessionState state,
    String? error,
  ) {
    switch (state) {
      case SshSessionState.connecting:
      case SshSessionState.authenticating:
      case SshSessionState.awaitingHostKey:
      case SshSessionState.reconnecting:
        return Row(
          key: Key('profile-connecting-${profile.identityKey}'),
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('Connecting…'),
          ],
        );
      case SshSessionState.failed:
        return _InlineError(
          identityKey: profile.identityKey,
          reason: (error != null && error.trim().isNotEmpty)
              ? error.trim()
              : 'The connection could not be established.',
          target: '${profile.host}:${profile.port}',
          onRetry: onRetry,
        );
      case SshSessionState.idle:
      case SshSessionState.connected:
      case SshSessionState.softDisconnected:
      case SshSessionState.disconnected:
        return null;
    }
  }
}

/// Compact inline failure state shown on a profile row (#660). REPLACES the
/// #648 blocking AlertDialog. Tapping the error text opens a (non-blocking,
/// explicitly-requested) detail dialog with the full reason; the Retry button
/// re-dispatches the connect via the row's [onRetry].
class _InlineError extends StatelessWidget {
  const _InlineError({
    required this.identityKey,
    required this.reason,
    required this.target,
    required this.onRetry,
  });

  final String identityKey;
  final String reason;
  final String target;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: InkWell(
            key: Key('profile-error-$identityKey'),
            onTap: () => _showDetail(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 14, color: errorColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: errorColor),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: Key('profile-retry-$identityKey'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onRetry,
          child: const Text('Retry'),
        ),
      ],
    );
  }

  void _showDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: Key('profile-error-detail-$identityKey'),
        title: const Text('Connection failed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(target, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(reason),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onRetry();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
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
