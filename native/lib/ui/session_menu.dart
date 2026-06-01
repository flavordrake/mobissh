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

class SessionMenu extends ConsumerWidget {
  const SessionMenu({super.key, required this.onClose});

  /// Dismisses the overlay. Replaces the old `Navigator.pop()` since the menu
  /// is no longer a route (#585).
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final keybarVisible = ref.watch(keybarVisibleProvider);
    final palette = ref.watch(activeTerminalThemeProvider);

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
          // Slim secondary controls (#567): no subtitles, dense rows. These
          // are session-scoped controls that belong in the sheet — keybar
          // visibility, terminal theme, and SFTP files.
          SwitchListTile(
            key: const Key('session-menu-keybar-toggle'),
            dense: true,
            secondary: const Icon(Icons.keyboard_outlined),
            title: const Text('Keybar'),
            value: keybarVisible,
            onChanged: (v) => ref.read(keybarVisibleProvider.notifier).set(v),
          ),
          // Cycle the terminal palette (#552). Tapping advances to the next
          // ported theme, wrapping at the end; the selection persists.
          ListTile(
            key: const Key('session-menu-theme-cycle'),
            dense: true,
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Theme'),
            trailing: Text(
              palette.label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => ref.read(terminalThemeProvider.notifier).cycle(),
          ),
          // Browse / download remote files over SFTP for the active session
          // (#559). Disabled when there's no active session.
          ListTile(
            key: const Key('session-menu-files'),
            dense: true,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Files'),
            trailing: const Icon(Icons.chevron_right),
            enabled: sessions.activeId != null,
            onTap: sessions.activeId == null
                ? null
                : () {
                    final sessionId = sessions.activeId!;
                    final navigator = Navigator.of(context);
                    onClose();
                    openFileBrowser(navigator.context, sessionId);
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
      title: Text(
        entry.label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        '${entry.username}@${entry.host}:${entry.port}',
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: IconButton(
        key: Key('session-menu-close-${entry.id}'),
        tooltip: 'Close session',
        icon: const Icon(Icons.close),
        onPressed: () {
          ref.read(sessionsProvider.notifier).close(entry.id);
        },
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
