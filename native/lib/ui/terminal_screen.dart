// Full-screen terminal screen — rendered when at least one SSH session is in
// `connected` state.
//
// Phase 2.A (#501): single session, one xterm.dart `TerminalView`.
// Phase 4 (#511): multi-session — horizontal tab strip + `IndexedStack`.
// #518: tab strip removed; session switching now happens through a session
// menu (modal bottom sheet, AppBar icon trigger). A bottom keybar with a
// visibility toggle in the session menu replaces the always-on chrome.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import 'keybar.dart';
import 'session_menu.dart';

class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final keybarVisible = ref.watch(keybarVisibleProvider);
    final entries = sessions.entries;

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
        ),
        leading: IconButton(
          key: const Key('session-menu-button'),
          tooltip: 'Sessions',
          icon: const Icon(Icons.menu),
          onPressed: () => showSessionMenu(context),
        ),
        actions: [
          IconButton(
            key: const Key('terminal-disconnect-button'),
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: () => activeEntry.controller.disconnect(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
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
            if (keybarVisible) Keybar(activeEntry: activeEntry),
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
