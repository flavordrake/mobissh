// Session menu (#518) — mirrors the PWA's `renderSessionList` / `initSessionMenu`.
//
// #567: slimmed to the session-menu-slim direction — terminal real estate is
// at a premium, so the sheet keeps only what belongs:
//   1. List of active sessions (tap to switch, long-press for actions).
//   2. "New session".
//   3. A compact secondary row of session controls (keybar toggle, theme,
//      files) — no verbose subtitles, no oversized header.
//
// Tap-to-switch dismisses the menu. Long-press opens a contextual menu with
// Disconnect / Close — same actions the PWA exposes on the session row.
//
// #585: the menu is presented as a NON-MODAL OverlayEntry, NOT a
// `showModalBottomSheet` route. Pushing a modal route swaps the active focus
// scope, so the engine hid the soft keyboard the instant the menu opened and
// the terminal reflowed ("jumpiness"). Restoring focus on dismiss couldn't fix
// the drop-on-OPEN — only not-pushing-a-route does. The overlay never requests
// focus (wrapped in a `FocusScope(canRequestFocus: false)`), so the terminal's
// text input keeps the keyboard. The panel floats just ABOVE the keyboard
// (offset by `viewInsets.bottom`) instead of being covered by it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import 'connect_form.dart';
import 'file_browser_screen.dart';

/// Opens the session menu as a NON-MODAL overlay anchored to the bottom, above
/// the keyboard. Returns once dismissed (outside tap or an action closes it).
///
/// Unlike `showModalBottomSheet`, this inserts an `OverlayEntry` rather than
/// pushing a route, so the terminal keeps primary focus and the soft keyboard
/// stays up (#585).
///
/// [bottomReserve] is the height (logical px) of the session bar that summoned
/// the menu. The panel floats ABOVE that reserved strip so its last row (Files)
/// never lands on top of the trigger — the owner hit "tap to dismiss lands on
/// Files" because the panel overlapped the bar (2026-06-01). The full-screen
/// tap barrier still covers the bar, so a tap on the (now-uncovered) trigger
/// dismisses the menu: same touch target opens AND closes it.
Future<void> showSessionMenu(BuildContext context, {double bottomReserve = 0}) {
  final overlay = Overlay.of(context);
  final completer = Completer<void>();
  late OverlayEntry entry;

  void close() {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete();
  }

  entry = OverlayEntry(
    builder: (ctx) {
      // Float the panel above the keyboard when it's up; sit just above the
      // session bar otherwise. This keeps the keyboard visible AND keeps the
      // bar's trigger uncovered so tapping it again dismisses (via the barrier).
      final keyboardInset = MediaQuery.of(ctx).viewInsets.bottom;
      final liftAboveBar = keyboardInset > 0 ? keyboardInset : bottomReserve;
      return Stack(
        children: [
          // Outside-tap barrier. A plain GestureDetector does NOT request
          // focus, so dismissing the menu doesn't disturb the keyboard either.
          // It covers the whole screen INCLUDING the session bar, so a tap on
          // the trigger that opened the menu dismisses it.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: liftAboveBar,
            // canRequestFocus:false guarantees the menu (and its tappable rows)
            // never steal focus from the terminal's editable — the keyboard
            // stays up. Taps still work; toggles/switches don't need focus.
            child: FocusScope(
              canRequestFocus: false,
              child: Material(
                color: Theme.of(ctx).colorScheme.surface,
                elevation: 8,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: SessionMenu(onClose: close),
              ),
            ),
          ),
        ],
      );
    },
  );

  overlay.insert(entry);
  return completer.future;
}

/// Step the ACTIVE session's font size by [delta] and PERSIST the result onto
/// its PROFILE (#640) so it survives restart/reconnect — mirroring how a
/// per-profile theme (#613) is stored on the profile, not just in-memory.
///
/// Two effects, in order:
///   1. In-memory per-session font (live render) via [SessionAppearanceNotifier]
///      — already clamped to [kFontSizeMin]..[kFontSizeMax].
///   2. Best-effort upsert of the clamped value onto the matching saved profile
///      (keyed by the active entry's `host:port:username`). NO-OP for an ad-hoc
///      connect with no saved profile — we never materialize one.
void _stepFont(
  WidgetRef ref,
  SessionsState sessions,
  String activeId,
  double delta,
) {
  final notifier = ref.read(sessionAppearanceProvider.notifier);
  notifier.adjustFontSize(activeId, delta);
  // The clamped in-memory value is now authoritative for this session.
  final size = ref.read(sessionFontSizeProvider(activeId));
  final active = sessions.active;
  if (active == null) return;
  // profileKey == the SavedProfile identityKey (host:port:username).
  unawaited(
    ref.read(profilesStoreProvider).setFontSize(active.profileKey, size),
  );
}

class SessionMenu extends ConsumerWidget {
  const SessionMenu({super.key, required this.onClose});

  /// Dismisses the overlay. Replaces the old `Navigator.pop()` since the menu
  /// is no longer a route (#585).
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final keybarVisible = ref.watch(keybarVisibleProvider);
    // Theme + font are PER-SESSION (#601, #571): the menu rows read and mutate
    // the ACTIVE session only. With no active session (empty list) these resolve
    // to the global default so the rows still render sensibly.
    final activeId = sessions.activeId;
    final palette = ref.watch(activeSessionThemeProvider);
    final fontSize = ref.watch(activeSessionFontSizeProvider);

    return SingleChildScrollView(
      child: Column(
        key: const Key('session-menu'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Slim grab-handle affordance (replaces showDragHandle, which only
          // came with the modal sheet).
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (sessions.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No sessions yet.'),
            )
          else
            for (final e in sessions.entries)
              _SessionRow(
                entry: e,
                isActive: e.id == sessions.activeId,
                onClose: onClose,
              ),
          // Start an additional session. Closes the menu and pushes the
          // connect chooser on top of the terminal screen (the goal's leg 2).
          ListTile(
            key: const Key('session-menu-new'),
            dense: true,
            leading: const Icon(Icons.add),
            title: const Text('New session'),
            onTap: () {
              final navigator = Navigator.of(context);
              onClose();
              navigator.push(
                MaterialPageRoute<void>(builder: (_) => const NewSessionPage()),
              );
            },
          ),
          const Divider(height: 1),
          // Slim per-session controls (#567): the five stacked full-width
          // ListTiles (keybar / theme / font / files / disconnect) regrew the
          // menu into clutter — the owner's #2 priority was to slim it back to
          // the PWA's tight direction. They now collapse into ONE compact row
          // of monochrome icon-buttons. Every essential control is KEPT and
          // keeps its existing key (so appearance/keybar/disconnect tests and
          // device screenshots still address them). All are session-scoped and
          // act on the ACTIVE session only (#601, #571).
          _SessionControlsRow(
            activeId: activeId,
            sessions: sessions,
            keybarVisible: keybarVisible,
            themeLabel: palette.label,
            fontSize: fontSize,
            onClose: onClose,
          ),
        ],
      ),
    );
  }
}

/// One compact row replacing the old stack of secondary ListTiles (#567).
///
/// Layout (left→right): theme cycle (icon + current label), font − [value] +,
/// keybar toggle, disconnect. (Files moved to a per-row icon, #649.)
/// Monochrome Material icons only — no emoji
/// (feedback_monochrome_icons_no_emoji). Controls disable themselves when there
/// is no active session, mirroring the prior per-tile `enabled` gating.
class _SessionControlsRow extends ConsumerWidget {
  const _SessionControlsRow({
    required this.activeId,
    required this.sessions,
    required this.keybarVisible,
    required this.themeLabel,
    required this.fontSize,
    required this.onClose,
  });

  final String? activeId;
  final SessionsState sessions;
  final bool keybarVisible;
  final String themeLabel;
  final double fontSize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasActive = activeId != null;
    return Padding(
      key: const Key('session-menu-controls'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Cycle the ACTIVE session's terminal palette (#601, #571). The
          // current theme label sits next to the icon so the control still
          // communicates state without a full row.
          InkWell(
            key: const Key('session-menu-theme-cycle'),
            borderRadius: BorderRadius.circular(8),
            onTap: !hasActive
                ? null
                : () => ref
                      .read(sessionAppearanceProvider.notifier)
                      .cycleTheme(activeId!),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.palette_outlined, size: 20),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 64),
                    child: Text(
                      themeLabel,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Font-size stepper for the ACTIVE session (#601): − [value] +.
          IconButton(
            key: const Key('session-menu-fontsize-dec'),
            tooltip: 'Decrease font size',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove),
            onPressed: !hasActive
                ? null
                : () => _stepFont(ref, sessions, activeId!, -kFontSizeStep),
          ),
          SizedBox(
            width: 22,
            child: Text(
              '${fontSize.round()}',
              key: const Key('session-menu-fontsize'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            key: const Key('session-menu-fontsize-inc'),
            tooltip: 'Increase font size',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add),
            onPressed: !hasActive
                ? null
                : () => _stepFont(ref, sessions, activeId!, kFontSizeStep),
          ),
          // Files moved to a PER-ROW affordance (#649): each session row now
          // carries its own `session-menu-files-${id}` icon next to its X, so
          // the browser opens for THAT row's session rather than only the
          // active one. The active-only control here was removed to avoid a
          // redundant second entry point.
          // Keybar visibility toggle. Filled icon = visible, outlined = hidden,
          // so the glyph itself communicates the toggle state (no SwitchListTile
          // row needed). Keybar visibility is global today; #573 moves it
          // per-session as a separate change — keep the wiring intact here.
          IconButton(
            key: const Key('session-menu-keybar-toggle'),
            tooltip: keybarVisible ? 'Hide keybar' : 'Show keybar',
            visualDensity: VisualDensity.compact,
            isSelected: keybarVisible,
            icon: const Icon(Icons.keyboard_outlined),
            selectedIcon: const Icon(Icons.keyboard),
            onPressed: () =>
                ref.read(keybarVisibleProvider.notifier).set(!keybarVisible),
          ),
          // Disconnect the ACTIVE session (#607). Fully closes (disconnect +
          // dispose + REMOVE the entry) so a re-connect restarts the service
          // (#564).
          IconButton(
            key: const Key('terminal-disconnect-button'),
            tooltip: 'Disconnect',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.link_off),
            onPressed: !hasActive
                ? null
                : () {
                    onClose();
                    ref.read(sessionsProvider.notifier).close(activeId!);
                  },
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({
    required this.entry,
    required this.isActive,
    required this.onClose,
  });

  final SessionEntry entry;
  final bool isActive;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      key: Key('session-menu-row-${entry.id}'),
      leading: Icon(
        Icons.terminal,
        color: isActive ? theme.colorScheme.primary : null,
      ),
      // #567: the label alone identifies the session (mirrors the PWA's slim
      // session list, which shows the label + a connection dot, no verbose
      // user@host:port subtitle). Dropping the subtitle halves each row's
      // height and tightens the menu.
      dense: true,
      title: Text(
        entry.label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      // [file icon][X] — the file icon opens the browser for THIS row's
      // session (#649); the X disconnects/closes THIS row's session. Both are
      // per-row so a multi-session menu addresses each session independently.
      // The file glyph is monochrome (Material `folder_outlined`, currentColor)
      // — no emoji (feedback_monochrome_icons_no_emoji).
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('session-menu-files-${entry.id}'),
            tooltip: 'Files',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.folder_outlined),
            // Open the file browser for THIS row's session id (its live SSH
            // connection drives SFTP), not just the active session. Close the
            // menu first so the browser route isn't covered by the overlay.
            onPressed: () {
              final sessionId = entry.id;
              final navigator = Navigator.of(context);
              onClose();
              openFileBrowser(navigator.context, sessionId);
            },
          ),
          IconButton(
            key: Key('session-menu-close-${entry.id}'),
            tooltip: 'Close session',
            icon: const Icon(Icons.close),
            onPressed: () {
              ref.read(sessionsProvider.notifier).close(entry.id);
            },
          ),
        ],
      ),
      onTap: () {
        ref.read(sessionsProvider.notifier).setActive(entry.id);
        onClose();
      },
      onLongPress: () => _showRowActions(context, ref),
    );
  }

  void _showRowActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('session-menu-action-disconnect'),
              leading: const Icon(Icons.link_off),
              title: const Text('Disconnect'),
              onTap: () {
                entry.proxy.disconnect();
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              key: const Key('session-menu-action-close'),
              leading: const Icon(Icons.close),
              title: const Text('Close session'),
              onTap: () {
                ref.read(sessionsProvider.notifier).close(entry.id);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
