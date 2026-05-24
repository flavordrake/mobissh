// Session menu (#518) — replaces the chip-row tab strip with a modal
// bottom sheet that mirrors the PWA's `renderSessionList` / `initSessionMenu`.
//
// Contents:
//   1. List of active sessions (tap to switch, long-press for actions).
//   2. A "Show keybar" toggle that flips the global `keybarVisibleProvider`.
//
// Tap-to-switch dismisses the menu. Long-press opens a contextual menu with
// Disconnect / Close — same actions the PWA exposes on the session row.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';

/// Opens the session menu as a modal bottom sheet. Returns once dismissed.
Future<void> showSessionMenu(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => const SessionMenu(),
  );
}

class SessionMenu extends ConsumerWidget {
  const SessionMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final keybarVisible = ref.watch(keybarVisibleProvider);

    return SafeArea(
      top: false,
      child: Column(
        key: const Key('session-menu'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Sessions',
              style: Theme.of(context).textTheme.titleMedium,
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
              ),
          const Divider(height: 1),
          SwitchListTile(
            key: const Key('session-menu-keybar-toggle'),
            title: const Text('Show keybar'),
            subtitle: const Text('Bottom row with Esc, Tab, arrows, Ctrl-C'),
            value: keybarVisible,
            onChanged: (v) =>
                ref.read(keybarVisibleProvider.notifier).set(v),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({required this.entry, required this.isActive});

  final SessionEntry entry;
  final bool isActive;

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
        Navigator.of(context).pop();
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
                entry.controller.disconnect();
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
