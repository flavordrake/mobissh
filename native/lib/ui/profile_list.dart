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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../state/profile_order_providers.dart';
import '../state/profiles_providers.dart';
import '../state/recent_sessions.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/profiles_store.dart';
import 'session_state_dot.dart';
import 'top_toast.dart';

typedef ProfileSelectCallback = void Function(SavedProfile profile);
typedef RecentSelectCallback = void Function(RecentSessionEntry entry);
typedef RecentReconnectAllCallback = void Function(
  List<RecentSessionEntry> entries,
);

class ProfileList extends ConsumerWidget {
  const ProfileList({
    super.key,
    required this.onConnect,
    required this.onEdit,
    this.onConnectRecent,
    this.onReconnectAll,
  });

  /// Fired when the user taps a profile row. Parent CONNECTS to the chosen
  /// profile immediately (resolve params + vault creds → addOrActivate →
  /// proxy.connect). This is the #579 tap-to-connect behavior — no separate
  /// Connect tap, no form round-trip. Also used by the row's RETRY affordance
  /// (#660) to re-dispatch the same connection.
  final ProfileSelectCallback onConnect;

  /// Fired when the user taps a row's edit pencil. Parent opens the profile
  /// editor pre-populated from the chosen profile (#579).
  final ProfileSelectCallback onEdit;

  /// Fired when the user one-taps a Recent Sessions row (#796, PWA #385).
  /// Parent resolves the matching saved profile (by identity) and connects.
  /// Null disables the recents group (e.g. callers that don't quick-connect).
  final RecentSelectCallback? onConnectRecent;

  /// Fired by "Reconnect All" when 2+ recents exist (#796, PWA #385).
  final RecentReconnectAllCallback? onReconnectAll;

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
        // Active Sessions group (#821 Slice 3, PWA `activeSessionList`): every
        // live OR dropped session renders at the TOP — connected sessions get a
        // Switch, dropped ones a Reconnect, all an ✕. This is the Connect-view
        // surface that keeps a DROPPED session reachable from the home screen
        // (#809) instead of it vanishing the moment recents are suppressed.
        final activeGroup = _buildActiveSessionsGroup(context, ref);

        // Recent Sessions group (#796, PWA #385): a one-tap quick-connect group
        // shown ABOVE the saved-profile list, ONLY on cold start (no sessions at
        // all) — exactly the PWA's `allSessions.length === 0` guard. It's
        // disabled entirely when the caller didn't wire [onConnectRecent].
        final recentsGroup = _buildRecentsGroup(context, ref);

        final Widget profilesSection;
        if (profiles.isEmpty) {
          profilesSection = const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No saved profiles. Import from PWA to skip retyping.',
              key: Key('profile-list-empty'),
              style: TextStyle(color: Colors.grey),
            ),
          );
        } else {
          // #481: the saved-profile list is user-reorderable (drag the
          // upper-right handle, or its tap-menu's Move to top / bottom). The
          // persisted order is applied here before rendering; the section
          // self-heals the stored order against add/delete/import.
          profilesSection = _SavedProfilesSection(
            profiles: profiles,
            onConnect: onConnect,
            onEdit: onEdit,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?activeGroup,
            ?recentsGroup,
            profilesSection,
          ],
        );
      },
    );
  }

  /// Build the Recent Sessions quick-connect group, or null when it should not
  /// render (no [onConnectRecent] callback, an active session exists, or no
  /// recents stored). Mirrors the PWA `renderProfiles` recent block (#385):
  /// header + one-tap rows + a "Reconnect All" button when there are >=2.
  Widget? _buildRecentsGroup(BuildContext context, WidgetRef ref) {
    final onTapRecent = onConnectRecent;
    if (onTapRecent == null) return null;

    // PWA parity (#821): the recents group only shows on TRUE cold start — when
    // there are NO sessions at all (the PWA `allSessions.length === 0` guard).
    // A DROPPED session is still a live SessionEntry, so it now surfaces in the
    // Active Sessions group above (never suppressed-invisible, #809). Recents
    // stay the pure cold-start quick-connect list.
    final hasAnySession = ref.watch(sessionsProvider).entries.isNotEmpty;
    if (hasAnySession) return null;

    final recents = ref.watch(recentSessionsProvider).valueOrNull ?? const [];
    if (recents.isEmpty) return null;

    return Column(
      key: const Key('recent-sessions-group'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            'Recent Sessions',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        // shrinkWrap: the group sits above the Expanded saved-profile list, so
        // it must size to its content rather than demand infinite height.
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: recents.length,
          itemBuilder: (context, i) {
            final r = recents[i];
            return _RecentTile(entry: r, onTap: () => onTapRecent(r));
          },
        ),
        // Action row: Reconnect All (only meaningful with 2+) on the left,
        // Clear flush RIGHT. Clear shows whenever the group renders — the group
        // itself only builds on a non-empty list, so there is always something
        // to clear even when Reconnect All is absent.
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Row(
            children: [
              if (recents.length >= 2)
                OutlinedButton.icon(
                  key: const Key('reconnect-all-recent'),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Reconnect All'),
                  onPressed: onReconnectAll == null
                      ? null
                      : () =>
                            onReconnectAll!(List<RecentSessionEntry>.from(recents)),
                ),
              const Spacer(),
              TextButton.icon(
                key: const Key('recent-sessions-clear'),
                // Monochrome Material glyph, no emoji (project rule). Small +
                // text-weight so it reads as secondary to Reconnect All.
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                onPressed: () => unawaited(_clearRecents(ref)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  /// Clear the stored recents, then invalidate so the watcher re-fetches and
  /// the group self-hides (it already returns null on an empty list). No
  /// confirm dialog: recents are a convenience cache, not user data — every
  /// entry is re-created by connecting, and saved profiles are untouched.
  Future<void> _clearRecents(WidgetRef ref) async {
    await ref.read(recentSessionsStoreProvider).clear();
    ref.invalidate(recentSessionsProvider);
  }

  /// Build the Active Sessions group (#821 Slice 3), or null when there are no
  /// sessions at all. Mirrors the PWA `activeSessionList` block in
  /// `loadProfiles`: an "Active Sessions" header, one row per session (connected
  /// → Switch, dropped → Reconnect, all → ✕), and a "Reconnect all" affordance
  /// when ANY session is non-connected. Brings the in-session menu's Slice-2
  /// surface (`session_menu.dart`) to the CONNECT view so a dropped session is
  /// reconnectable from the home screen instead of vanishing (#809).
  Widget? _buildActiveSessionsGroup(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(sessionsProvider).entries;
    if (entries.isEmpty) return null;

    return Column(
      key: const Key('active-sessions-group'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            'Active Sessions',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        // shrinkWrap: this group sits above the Expanded saved-profile list, so
        // it sizes to its content rather than demanding infinite height.
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: entries.length,
          itemBuilder: (context, i) => _ActiveSessionTile(entry: entries[i]),
        ),
        _ActiveReconnectAllRow(entries: entries),
        const Divider(height: 1),
      ],
    );
  }
}

/// One Active Sessions row in the Connect view (#821 Slice 3). Mirrors the PWA
/// `active-session-item`: a state-driven status dot + the session label, a
/// per-state primary action (Switch when connected, Reconnect when dropped),
/// and an always-present ✕ (forget). Reactive via a [StreamBuilder] on the
/// proxy state so the row repaints as the session moves connected ↔ dropped
/// without re-entering the chooser — exactly the in-menu `_SessionRow` (#817)
/// behaviour, brought to the home screen.
class _ActiveSessionTile extends ConsumerWidget {
  const _ActiveSessionTile({required this.entry});

  final SessionEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileColor = ref.watch(sessionColorProvider(entry.id));
    return StreamBuilder<SshSessionData>(
      stream: entry.proxy.stream,
      initialData: entry.proxy.data,
      builder: (context, snapshot) {
        final state = snapshot.data?.state ?? entry.proxy.data.state;
        return _buildRow(context, ref, state, profileColor);
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    WidgetRef ref,
    SshSessionState state,
    Color? profileColor,
  ) {
    final canReconnect = sessionCanReconnect(state);
    return ListTile(
      key: Key('active-session-tile-${entry.id}'),
      dense: true,
      leading: SessionStateDot(
        key: Key('active-session-dot-${entry.id}'),
        swatchKey: Key('active-session-swatch-${entry.id}'),
        state: state,
        profileColor: profileColor,
      ),
      title: Text(entry.label, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${entry.username}@${entry.host}:${entry.port}',
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canReconnect)
            // Reconnect a dropped session from held params / re-resolved creds
            // (#817). Routed through the notifier so the foreground task isolate
            // is (re)started first — a bare proxy.reconnect() would buffer
            // against a dead isolate forever after a last-session drop.
            IconButton(
              key: Key('active-session-reconnect-${entry.id}'),
              tooltip: 'Reconnect',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.replay),
              onPressed: () =>
                  ref.read(sessionsProvider.notifier).reconnect(entry.id),
            )
          else
            // Connected (or still connecting): Switch makes this the active
            // session and returns to the terminal. `maybePop` returns to the
            // live terminal when this list is a pushed route OVER a session
            // (#721); at the cold-start root there's nothing to pop and the
            // router already shows the terminal for a connected session.
            IconButton(
              key: Key('active-session-switch-${entry.id}'),
              tooltip: 'Switch to session',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.login),
              onPressed: () {
                ref.read(sessionsProvider.notifier).setActive(entry.id);
                Navigator.of(context).maybePop();
              },
            ),
          // ✕ ALWAYS present — "forget this session" (explicit close), the same
          // contract as the in-menu row (#817).
          IconButton(
            key: Key('active-session-close-${entry.id}'),
            tooltip: 'Close session',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: () =>
                ref.read(sessionsProvider.notifier).close(entry.id),
          ),
        ],
      ),
      // A whole-row tap switches to the session (PWA `data-action="switch"`),
      // same as the explicit Switch button.
      onTap: () {
        ref.read(sessionsProvider.notifier).setActive(entry.id);
        Navigator.of(context).maybePop();
      },
    );
  }
}

/// "Reconnect all" for the Connect-view Active Sessions group (#821 Slice 3).
/// Shown only when at least one session is in a manually-reconnectable drop
/// state; each tap reconnects every dropped session (held params / re-resolved
/// creds). Subscribes to every entry's proxy state so it appears/disappears
/// reactively — the same pattern as the in-menu `_ReconnectAllRow` (#817).
class _ActiveReconnectAllRow extends ConsumerStatefulWidget {
  const _ActiveReconnectAllRow({required this.entries});

  final List<SessionEntry> entries;

  @override
  ConsumerState<_ActiveReconnectAllRow> createState() =>
      _ActiveReconnectAllRowState();
}

class _ActiveReconnectAllRowState
    extends ConsumerState<_ActiveReconnectAllRow> {
  final List<StreamSubscription<SshSessionData>> _subs = [];

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_ActiveReconnectAllRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resubscribe();
  }

  void _subscribe() {
    for (final e in widget.entries) {
      _subs.add(
        e.proxy.stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  void _resubscribe() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _subscribe();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dropped = widget.entries
        .where((e) => sessionCanReconnect(e.proxy.data.state))
        .toList();
    if (dropped.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: OutlinedButton.icon(
        key: const Key('active-sessions-reconnect-all'),
        icon: const Icon(Icons.restart_alt, size: 18),
        label: Text(
          dropped.length == 1
              ? 'Reconnect'
              : 'Reconnect all (${dropped.length})',
        ),
        onPressed: () async {
          // #959: same batch seam as the in-menu row — per-session isolation
          // plus a summary so a set where ONE machine refuses to come back is
          // distinguishable from a clean one. The root overlay is resolved
          // BEFORE the await so the verdict survives a route change.
          final notifier = ref.read(sessionsProvider.notifier);
          final overlay = Overlay.maybeOf(context, rootOverlay: true);
          final result = await notifier.reconnectAll(
            [for (final e in dropped) e.id],
          );
          if (overlay == null || !overlay.mounted) return;
          showTopToastInOverlay(overlay, reconnectAllSummary(result));
        },
      ),
    );
  }
}

/// One Recent Sessions row (#796). A whole-row tap quick-connects (PWA `data-
/// action="reconnect-recent"`). Monochrome leading dot + a trailing replay glyph
/// signal "reconnect" without a colorful emoji icon.
class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.entry, required this.onTap});

  final RecentSessionEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = entry.title.isNotEmpty
        ? entry.title
        : '${entry.username}@${entry.host}:${entry.port}';
    return ListTile(
      key: Key('recent-tile-${entry.identityKey}'),
      dense: true,
      leading: Icon(
        Icons.history,
        size: 18,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(label, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${entry.username}@${entry.host}:${entry.port}',
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        key: Key('recent-reconnect-${entry.identityKey}'),
        icon: const Icon(Icons.replay),
        tooltip: 'Reconnect',
        onPressed: onTap,
      ),
      onTap: onTap,
    );
  }
}

/// The reorderable "Saved Profiles" section (#481). Applies the persisted
/// [profileOrderProvider] order to [profiles] before rendering, and renders a
/// [ReorderableListView] whose ONLY drag affordance is each tile's upper-right
/// handle (`buildDefaultDragHandles: false`). The card body keeps its
/// tap-to-connect (#579) and the edit pencil keeps editing.
///
/// The stored order self-heals against add/delete/import inside the provider
/// (it `sync`s off [savedProfilesProvider]) — no plumbing needed here. The
/// Recent / Active sessions groups above are separate and untouched.
class _SavedProfilesSection extends ConsumerWidget {
  const _SavedProfilesSection({
    required this.profiles,
    required this.onConnect,
    required this.onEdit,
  });

  final List<SavedProfile> profiles;
  final ProfileSelectCallback onConnect;
  final ProfileSelectCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(profileOrderProvider);
    final ordered = applyOrder(profiles, order);

    return Expanded(
      key: const Key('profile-list-populated'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              'Saved Profiles',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          // #643: the list FILLS the available height (Expanded), scrolling
          // within it. #481: ReorderableListView gives lift/part + auto-scroll
          // near the edges during a drag. Default drag handles are OFF — only
          // each tile's upper-right handle starts a drag.
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: ordered.length,
              // onReorderItem (not the deprecated onReorder): newIndex is the
              // destination AFTER removal, which the notifier consumes directly.
              onReorderItem: (oldIndex, newIndex) {
                ref
                    .read(profileOrderProvider.notifier)
                    .reorder(oldIndex, newIndex);
              },
              itemBuilder: (context, i) {
                final p = ordered[i];
                return _ProfileTile(
                  key: ValueKey('profile-reorder-${p.identityKey}'),
                  index: i,
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
      ),
    );
  }
}

/// One profile row. A [ConsumerWidget] so it can watch the session collection
/// and reflect the matching session's live connect state inline (#660).
class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({
    super.key,
    required this.index,
    required this.profile,
    required this.onTap,
    required this.onEdit,
    required this.onRetry,
  });

  /// This tile's position in the rendered (ordered) list — the drag index for
  /// the upper-right [ReorderableDelayedDragStartListener] handle (#481).
  final int index;

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

    // The body is the existing ListTile (tap-to-connect + edit pencil). The
    // reorder handle is overlaid in the UPPER-RIGHT corner (#481) so ONLY the
    // glyph drags / opens the menu — the card body stays tap-to-connect.
    return Stack(
      children: [
        ListTile(
          key: Key('profile-tile-${profile.identityKey}'),
          dense: true,
          leading: CircleAvatar(
            backgroundColor: color ?? Theme.of(context).colorScheme.primary,
            radius: 8,
          ),
          title: Text(profile.title, overflow: TextOverflow.ellipsis),
          // The subtitle carries the host line PLUS — when a matching session
          // is mid-connect or failed — an inline connect affordance (#660). It
          // stays reactive by streaming the matching session's proxy state.
          subtitle: _ProfileSubtitle(
            profile: profile,
            entry: entry,
            onRetry: onRetry,
          ),
          // Reserve right room for the overlaid handle + pencil so long titles
          // don't run under them.
          contentPadding: const EdgeInsets.only(left: 16, right: 88),
          onTap: onTap,
        ),
        // Upper-right control cluster: edit pencil + reorder/menu handle.
        Positioned(
          top: 0,
          right: 0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Edit pencil opens the editor; the body tap connects. Distinct
              // targets so a body tap never accidentally edits (PWA parity).
              IconButton(
                key: Key('profile-edit-${profile.identityKey}'),
                icon: const Icon(Icons.edit_outlined, size: 20),
                visualDensity: VisualDensity.compact,
                tooltip: 'Edit profile',
                onPressed: onEdit,
              ),
              _ReorderHandle(index: index, profile: profile),
            ],
          ),
        ),
      ],
    );
  }
}

/// The upper-right drag-grip / menu glyph for a profile card (#481).
///
/// Press-and-DRAG → reorder (via [ReorderableDragStartListener] — IMMEDIATE, no
/// hold). TAP → a popup menu with at least "Move to top" / "Move to bottom".
/// Only this glyph initiates drag/menu; the card body keeps tap-to-connect
/// (rules/platform/mobile-touch.md — dedicated control, not an overloaded body
/// gesture). `Icons.drag_indicator` is a monochrome Material glyph (no emoji),
/// ~18px in a ≥32px tap target.
///
/// DEVICE FIX (#481 follow-up): the drag was DEAD on device — the previous
/// [PopupMenuButton] installs a `tooltip`, and a tooltip wires a
/// [LongPressGestureRecognizer]; combined with a *delayed* drag listener BOTH
/// fired at the 500ms timeout and the long-press won the gesture arena,
/// swallowing every drag (the exact "tooltip long-press recognizer eats the
/// gesture → bare InkResponse" trap from project memory). So: NO PopupMenuButton
/// / IconButton / tooltip here. A bare [InkResponse] owns the tap (opens the
/// menu via [showMenu]); an IMMEDIATE [ReorderableDragStartListener] owns the
/// drag (press-and-move reorders, no hold required). The two recognizers are
/// arena-disjoint — a tap (no movement) opens the menu, any movement starts the
/// drag.
class _ReorderHandle extends ConsumerWidget {
  const _ReorderHandle({required this.index, required this.profile});

  final int index;
  final SavedProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = profile.identityKey;
    return ReorderableDragStartListener(
      index: index,
      child: InkResponse(
        key: Key('profile-reorder-handle-$id'),
        radius: 22,
        onTap: () => _openMenu(context, ref, id),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.drag_indicator, size: 18),
        ),
      ),
    );
  }

  /// Open the Move menu anchored at the handle. Uses [showMenu] directly (NOT
  /// PopupMenuButton) so no tooltip long-press recognizer competes with the
  /// drag. Items keep their stable keys so the widget tests still resolve them.
  Future<void> _openMenu(BuildContext context, WidgetRef ref, String id) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final handle = context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        handle.localToGlobal(Offset.zero, ancestor: overlay),
        handle.localToGlobal(
          handle.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final value = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          key: Key('profile-move-top-$id'),
          value: 'top',
          child: const Row(
            children: [
              Icon(Icons.vertical_align_top, size: 18),
              SizedBox(width: 12),
              Text('Move to top'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          key: Key('profile-move-bottom-$id'),
          value: 'bottom',
          child: const Row(
            children: [
              Icon(Icons.vertical_align_bottom, size: 18),
              SizedBox(width: 12),
              Text('Move to bottom'),
            ],
          ),
        ),
      ],
    );
    if (value == 'top') {
      ref.read(profileOrderProvider.notifier).moveToTop(id);
    } else if (value == 'bottom') {
      ref.read(profileOrderProvider.notifier).moveToBottom(id);
    }
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
