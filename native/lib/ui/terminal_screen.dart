// Full-screen terminal screen — rendered when at least one SSH session is in
// `connected` state.
//
// Phase 2.A (#501): single session, one xterm.dart `TerminalView`.
// Phase 4 (#511): multi-session — horizontal tab strip + `IndexedStack`.
// #518: tab strip removed; session switching now happens through a session
// menu (modal bottom sheet). A bottom keybar with a visibility toggle in the
// session menu replaces the always-on chrome.
// #566: the session-menu trigger moved OFF the top-left AppBar to a slim
// BOTTOM session bar (thumb-reachable on a phone). The bar shows the active
// session label and opens the bottom sheet — mirroring the PWA's persistent
// session bar (`#sessionMenuBtn` in the bottom handle strip). The bar is
// deliberately a single full-width tap target, leaving a clean seam for a
// future swipe-to-switch gesture (#568). #567: the sheet itself is slimmed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import 'keybar.dart';
import 'session_menu.dart';

/// Bundled monospace family declared in `pubspec.yaml` (#552). The xterm
/// `TerminalStyle.fontFamilyFallback` (platform monospace) covers glyphs the
/// bundled face is missing, so this stays robust even if the asset is absent.
const String kTerminalFontFamily = 'JetBrainsMono';

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

    // No top AppBar (#566 follow-up): terminal real estate is at a premium and
    // the PWA is a full-screen terminal with bottom-only chrome. The session
    // label + menu + disconnect all live on the bottom session bar; the
    // terminal fills from the status bar down.
    return Scaffold(
      body: SafeArea(
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
            // Bottom session bar (#566): the thumb-reachable trigger for the
            // session menu (tap the label area) + a disconnect affordance at the
            // right edge. Sits below the keybar so the menu sheet rises from
            // immediately above the affordance that summoned it. The label tap
            // target leaves a clean seam for swipe-to-switch (#568).
            _SessionBar(
              label: activeEntry.label,
              sessionCount: entries.length,
              onDisconnect: () =>
                  ref.read(sessionsProvider.notifier).close(activeEntry.id),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim bottom bar that opens the session menu (#566). Mirrors the PWA's
/// persistent session bar: active session label + a count badge when more than
/// one session is open, tappable across its full width.
class _SessionBar extends StatelessWidget {
  const _SessionBar({
    required this.label,
    required this.sessionCount,
    required this.onDisconnect,
  });

  final String label;
  final int sessionCount;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('session-bar'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              // `session-menu-button` is retained as the stable terminal-screen-
              // mounted marker that smoke/integration tests poll for; it moved
              // from the AppBar to the bottom bar. `session-bar-open-menu` is the
              // screenshot/test-addressable name for the menu affordance.
              key: const Key('session-bar-open-menu'),
              onTap: () => showSessionMenu(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  key: const Key('session-menu-button'),
                  children: [
                    const Icon(Icons.menu, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (sessionCount > 1)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$sessionCount',
                          style: TextStyle(
                            color: theme.colorScheme.onPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(width: 6),
                    const Icon(Icons.expand_less, size: 18),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('terminal-disconnect-button'),
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off, size: 18),
            // Fully close the session (disconnect + dispose + REMOVE the entry)
            // so a re-connect re-creates it + restarts the service (#564).
            onPressed: onDisconnect,
          ),
        ],
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
    final fontSize = ref.watch(fontSizeProvider);
    final palette = ref.watch(activeTerminalThemeProvider);

    return Column(
      children: [
        if (shellAsync.hasError)
          Container(
            width: double.infinity,
            color: Colors.red.shade900,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
            theme: palette.theme,
            textStyle: TerminalStyle(
              fontSize: fontSize,
              fontFamily: kTerminalFontFamily,
            ),
          ),
        ),
      ],
    );
  }
}
