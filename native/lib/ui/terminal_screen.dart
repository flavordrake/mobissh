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
// #568: that seam is now wired — a horizontal swipe on the bottom session bar
// switches the active session (ring-wrap, haptic), and a long-press on the
// terminal opens a Copy / Select all / Paste context menu. The swipe handler
// lives on the bar (NOT the TerminalView) so it never steals the terminal's
// hardcoded vertical-scroll gesture; selection stays xterm.dart's domain (no
// custom overlay — see terminal_context_menu.dart for the rationale).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import 'keybar.dart';
import 'session_menu.dart';
import 'terminal_context_menu.dart';

/// Minimum horizontal travel (logical px) before a drag on the session bar is
/// treated as a swipe-to-switch. Matches the ~50px threshold in the design so
/// a small horizontal wobble during a tap doesn't switch sessions.
const double kSessionSwipeThreshold = 50;

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
              // Swipe left → next session, swipe right → previous, wrapping
              // around the session ring (#568). No-op with a single session.
              onSwipe: (delta) {
                if (entries.length < 2) return;
                final from = activeIndex < 0 ? 0 : activeIndex;
                final count = entries.length;
                final target = (from + delta) % count;
                final nextIndex = target < 0 ? target + count : target;
                ref
                    .read(sessionsProvider.notifier)
                    .setActive(entries[nextIndex].id);
                HapticFeedback.lightImpact();
              },
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
///
/// #568: a horizontal swipe across the bar switches sessions. The drag
/// recognizer lives here (a sibling of the TerminalView, not its parent) so it
/// can never steal the terminal's hardcoded vertical-scroll gesture. A swipe
/// suppresses the immediately-following tap so a swipe doesn't also open the
/// session menu.
class _SessionBar extends StatefulWidget {
  const _SessionBar({
    required this.label,
    required this.sessionCount,
    required this.onSwipe,
    required this.onDisconnect,
  });

  final String label;
  final int sessionCount;

  /// Called when a horizontal swipe crosses the threshold. `delta` is `+1` for
  /// a left swipe (next session) and `-1` for a right swipe (previous).
  final ValueChanged<int> onSwipe;

  final VoidCallback onDisconnect;

  @override
  State<_SessionBar> createState() => _SessionBarState();
}

class _SessionBarState extends State<_SessionBar> {
  /// Accumulated horizontal travel for the in-flight drag.
  double _dragDx = 0;

  /// Set true once a drag crosses [kSessionSwipeThreshold] so the InkWell's
  /// `onTap` (which fires after the gesture resolves) doesn't also open the
  /// session menu. Reset on the next drag start.
  bool _swipeOccurred = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      // Opaque so the bar consumes the drag early rather than leaking it to
      // ancestors, and so the whole bar width is a swipe target.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        _dragDx = 0;
        _swipeOccurred = false;
      },
      onHorizontalDragUpdate: (details) {
        _dragDx += details.delta.dx;
      },
      onHorizontalDragEnd: (_) {
        if (_dragDx.abs() < kSessionSwipeThreshold) return;
        _swipeOccurred = true;
        // Moving content left (negative dx) advances to the next session;
        // moving right (positive dx) goes to the previous one.
        widget.onSwipe(_dragDx < 0 ? 1 : -1);
      },
      child: _buildBar(context, theme),
    );
  }

  Widget _buildBar(BuildContext context, ThemeData theme) {
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
              onTap: () {
                // Suppress the tap that fires at the tail of a swipe so a
                // swipe-to-switch doesn't also pop the session menu (#568).
                if (_swipeOccurred) {
                  _swipeOccurred = false;
                  return;
                }
                // Pass the bar's own height so the menu panel floats ABOVE the
                // bar (not over it) — the last menu row no longer lands on the
                // trigger, and a second tap on the trigger dismisses via the
                // overlay barrier (owner 2026-06-01). `context` here is the
                // _SessionBar element, so `context.size` is the bar's height.
                showSessionMenu(
                  context,
                  bottomReserve: context.size?.height ?? 0,
                );
              },
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
                        widget.label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (widget.sessionCount > 1)
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
                          '${widget.sessionCount}',
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
            onPressed: widget.onDisconnect,
          ),
        ],
      ),
    );
  }
}

/// One session's terminal body. Watches the shell provider so the PTY opens
/// when the session reaches `connected`. Hidden tabs still subscribe — their
/// `Terminal` buffer fills in the background.
///
/// #568: owns a per-session [TerminalController] so the long-press context
/// menu can READ the current selection (`terminal.buffer.getText(...)`) and
/// drive `setSelection` / `clearSelection`. We never render selection
/// ourselves — that stays xterm.dart's canvas.
class _SessionTerminalBody extends ConsumerStatefulWidget {
  const _SessionTerminalBody({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_SessionTerminalBody> createState() =>
      _SessionTerminalBodyState();
}

class _SessionTerminalBodyState extends ConsumerState<_SessionTerminalBody> {
  final TerminalController _terminalController = TerminalController();

  @override
  void dispose() {
    _terminalController.dispose();
    super.dispose();
  }

  /// Long-press (touch) or right-click (desktop) on the terminal →
  /// Copy / Select all / Paste. Copy and Paste both route through xterm.dart's
  /// own buffer + the session proxy; nothing here renders or mirrors selection
  /// state.
  ///
  /// #584: this is now bound to BOTH a real long-press recognizer (touch) and
  /// the TerminalView's `onSecondaryTapDown` (desktop right-click). It was
  /// previously secondary-tap-only, so a touch long-press never opened it —
  /// the menu was invisible on a phone.
  Future<void> _showContextMenu(
    Offset globalPosition,
    Terminal terminal,
  ) async {
    final selection = _terminalController.selection;
    showTerminalContextMenu(
      context,
      globalPosition: globalPosition,
      actions: TerminalContextMenuActions(
        hasSelection: selection != null,
        onCopy: () {
          final range = _terminalController.selection;
          if (range == null) return;
          final text = terminal.buffer.getText(range);
          Clipboard.setData(ClipboardData(text: text));
        },
        onSelectAll: () {
          final buffer = terminal.buffer;
          _terminalController.setSelection(
            buffer.createAnchor(0, buffer.height - terminal.viewHeight),
            buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
            mode: SelectionMode.line,
          );
        },
        onPaste: () async {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          final text = data?.text;
          if (text == null || text.isEmpty) return;
          // Route paste through the active session proxy (same path as typed
          // keystrokes) rather than terminal.paste() so bytes reach the SSH
          // PTY hosted in the task isolate (#568 spec).
          final entry = ref.read(sessionsProvider).active;
          entry?.proxy.sendInput(Uint8List.fromList(utf8.encode(text)));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final terminal = ref.watch(terminalProvider(widget.sessionId));
    final shellAsync = ref.watch(sshShellProvider(widget.sessionId));
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
          // #584: a long-press recognizer wraps the TerminalView so a touch
          // long-press opens the context menu. A LongPressGestureRecognizer is
          // distinct from xterm's tap + vertical-scroll-drag recognizers in the
          // gesture arena, so it only wins for a stationary press and never
          // steals the terminal's scroll. `deferToChild` keeps the opaque
          // TerminalView the hit-test target; the ancestor detector still
          // participates in the arena for that pointer.
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onLongPressStart: (details) =>
                _showContextMenu(details.globalPosition, terminal),
            child: TerminalView(
              terminal,
              key: Key('terminal-view-${widget.sessionId}'),
              controller: _terminalController,
              autofocus: false,
              padding: const EdgeInsets.all(4),
              theme: palette.theme,
              textStyle: TerminalStyle(
                fontSize: fontSize,
                fontFamily: kTerminalFontFamily,
              ),
              onSecondaryTapDown: (details, _) =>
                  _showContextMenu(details.globalPosition, terminal),
            ),
          ),
        ),
      ],
    );
  }
}
