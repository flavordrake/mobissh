// Full-screen terminal screen — rendered when at least one SSH session is in
// `connected` state.
//
// Phase 2.A (#501): single session, one xterm.dart `TerminalView`.
// Phase 4 (#511): multi-session — horizontal tab strip at the top, then an
// `IndexedStack` of per-session `TerminalView` widgets keyed by session id.
// Hidden tabs stay alive (subscriptions keep filling their buffer); only the
// active one paints.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';
import '../state/terminal_providers.dart';

class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final entries = sessions.entries;
    final activeId = sessions.activeId;

    if (entries.isEmpty) {
      // Defensive: router should switch back to ConnectHomePage. Render a
      // placeholder rather than crashing if we ever land here mid-transition.
      return const Scaffold(body: Center(child: Text('No sessions')));
    }

    final activeEntry = sessions.active ?? entries.first;
    final activeIndex = entries.indexWhere((e) => e.id == activeEntry.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          activeEntry.label,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
        actions: [
          IconButton(
            key: const Key('terminal-disconnect-button'),
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: () => activeEntry.controller.disconnect(),
          ),
        ],
        bottom: _SessionTabStrip(
          entries: entries,
          activeId: activeId,
        ),
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: activeIndex < 0 ? 0 : activeIndex,
          children: [
            for (final e in entries)
              _SessionTerminalBody(
                key: ValueKey('terminal-body-${e.id}'),
                sessionId: e.id,
              ),
          ],
        ),
      ),
    );
  }
}

/// Tab strip rendered as `AppBar.bottom`. Each chip is keyed so widget tests
/// can locate them. Tap → setActive; long-press → action sheet.
class _SessionTabStrip extends ConsumerWidget
    implements PreferredSizeWidget {
  const _SessionTabStrip({
    required this.entries,
    required this.activeId,
  });

  final List<SessionEntry> entries;
  final String? activeId;

  @override
  Size get preferredSize => const Size.fromHeight(40);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: ListView.builder(
        key: const Key('session-tab-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          final isActive = e.id == activeId;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: GestureDetector(
              key: Key('session-tab-${e.id}'),
              onTap: () => ref.read(sessionsProvider.notifier).setActive(e.id),
              onLongPress: () => _showTabActions(context, ref, e),
              child: Chip(
                label: Text(
                  e.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: isActive
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                backgroundColor: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          );
        },
      ),
    );
  }

  void _showTabActions(BuildContext context, WidgetRef ref, SessionEntry e) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('tab-action-disconnect'),
              leading: const Icon(Icons.link_off),
              title: const Text('Disconnect'),
              onTap: () {
                e.controller.disconnect();
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              key: const Key('tab-action-close'),
              leading: const Icon(Icons.close),
              title: const Text('Close tab'),
              onTap: () {
                ref.read(sessionsProvider.notifier).close(e.id);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One session's terminal body. Watches the shell provider so the PTY opens
/// when the session reaches `connected`. Hidden tabs still subscribe — their
/// `Terminal` buffer fills in the background.
class _SessionTerminalBody extends ConsumerWidget {
  const _SessionTerminalBody({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminal = ref.watch(terminalProvider(sessionId));
    final shellAsync = ref.watch(sshShellProvider(sessionId));

    return Column(
      children: [
        if (shellAsync.hasError)
          Container(
            width: double.infinity,
            color: Colors.red.shade900,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              'Shell error: ${shellAsync.error}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        Expanded(
          child: TerminalView(
            terminal,
            key: Key('terminal-view-$sessionId'),
            autofocus: false,
            padding: const EdgeInsets.all(4),
          ),
        ),
      ],
    );
  }
}
