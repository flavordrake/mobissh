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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import 'compose_bar.dart';
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
    final composeBarVisible = ref.watch(composeBarVisibleProvider);
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
      // resizeToAvoidBottomInset:false — the floating compose bar (#604) owns
      // the keyboard inset itself (it positions above the keyboard), so the
      // Scaffold shouldn't also reflow the terminal Column when the keyboard
      // opens. This keeps the terminal cursor from jumping while composing.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Stack(
          children: [
            // The terminal + chrome column.
            Column(
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
                  composeOn: composeBarVisible,
                  onToggleCompose: () =>
                      ref.read(composeBarVisibleProvider.notifier).toggle(),
                ),
              ],
            ),
            // Floating compose bar (#604): overlays the terminal as a draggable
            // panel rather than docking in the Column, so it never pushes the
            // terminal up / scrolls the cursor out of view. Keyed by the active
            // session so switching gives a fresh field bound to the right
            // terminal. Toggled from the session bar's compose button (#607).
            if (composeBarVisible)
              ComposeBar(
                key: ValueKey('compose-bar-${activeEntry.id}'),
                terminal: activeEntry.terminal,
                onClose: () =>
                    ref.read(composeBarVisibleProvider.notifier).set(false),
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
    required this.composeOn,
    required this.onToggleCompose,
  });

  final String label;
  final int sessionCount;

  /// Called when a horizontal swipe crosses the threshold. `delta` is `+1` for
  /// a left swipe (next session) and `-1` for a right swipe (previous).
  final ValueChanged<int> onSwipe;

  /// #607: the bar's right-edge button toggles the compose bar (a per-moment
  /// action), replacing the old disconnect button (disconnect moved into the
  /// session menu — it's infrequent). [composeOn] drives the icon state.
  final bool composeOn;
  final VoidCallback onToggleCompose;

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
                    // #607: hamburger with the session-count badge folded onto
                    // it (count moved LEFT). No expand_less up-arrow — session
                    // switching is left/right SWIPE (#568), so an "expand"
                    // affordance was misleading.
                    _MenuIconWithCount(count: widget.sessionCount),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // #607: compose-bar toggle replaces the disconnect button. Reflects
          // on/off; disconnect now lives in the session menu.
          IconButton(
            key: const Key('session-bar-compose-toggle'),
            tooltip: widget.composeOn
                ? 'Hide compose bar'
                : 'Compose (swipe / voice)',
            isSelected: widget.composeOn,
            color: widget.composeOn ? theme.colorScheme.primary : null,
            icon: const Icon(Icons.edit_note_outlined, size: 20),
            onPressed: widget.onToggleCompose,
          ),
        ],
      ),
    );
  }
}

/// Hamburger menu icon with the session-count badge folded onto it (#607).
/// The count moved LEFT (onto the menu affordance) from its old mid-bar spot;
/// the badge only shows when more than one session is open.
class _MenuIconWithCount extends StatelessWidget {
  const _MenuIconWithCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = const Icon(Icons.menu, size: 18);
    if (count <= 1) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -8,
          top: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: theme.colorScheme.onPrimary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
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

  /// Passed to TerminalView so we own the scrollback Scrollable (#605). Having
  /// an explicit controller also lets future work jump-to-bottom on new output.
  final ScrollController _scrollController = ScrollController();

  // ── Listener-based long-press (#605) ──────────────────────────────────────
  // We detect a stationary hold via raw pointer events instead of a
  // GestureDetector, so we never enter the gesture arena and never compete
  // with xterm's vertical scroll. A hold fires the context menu only if the
  // pointer stays within [_kLongPressSlop] for [_kLongPressDuration].
  static const Duration _kLongPressDuration = Duration(milliseconds: 500);
  static const double _kLongPressSlop = 12;
  Timer? _longPressTimer;
  Offset? _pointerDownPos;
  Terminal? _pendingMenuTerminal;

  void _onPointerDown(PointerDownEvent e) {
    // Only touch holds open the menu; mouse uses onSecondaryTapDown.
    if (e.kind != PointerDeviceKind.touch) return;
    _pointerDownPos = e.position;
    _pendingMenuTerminal = ref.read(terminalProvider(widget.sessionId));
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPressDuration, () {
      final pos = _pointerDownPos;
      final terminal = _pendingMenuTerminal;
      if (pos != null && terminal != null && mounted) {
        _showContextMenu(pos, terminal);
      }
      _cancelLongPress();
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    // A drag past the slop is a scroll, not a hold — cancel the pending menu so
    // scrollback scrolling is never interrupted.
    final down = _pointerDownPos;
    if (down != null && (e.position - down).distance > _kLongPressSlop) {
      _cancelLongPress();
    }
  }

  void _onPointerUp(PointerUpEvent e) => _cancelLongPress();

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _pointerDownPos = null;
    _pendingMenuTerminal = null;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _scrollController.dispose();
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
    // Per-session theme + font (#601, #571): each session's TerminalView reads
    // ITS OWN palette + font size, so two visible sessions can differ.
    final fontSize = ref.watch(sessionFontSizeProvider(widget.sessionId));
    final palette = ref.watch(sessionTerminalThemeProvider(widget.sessionId));

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
          // #605 scrollback fix: the long-press context menu is driven by a
          // `Listener` (raw pointer events), NOT a wrapping GestureDetector.
          //
          // The old GestureDetector(onLongPressStart) added a
          // LongPressGestureRecognizer that COMPETED with xterm's internal
          // vertical-scroll recognizer in the gesture arena — `deferToChild`
          // only changes hit-testing, not arena competition — so a slow drag
          // would lose to the pending 500ms long-press and scrollback drag
          // failed intermittently. A Listener observes pointer down/move/up
          // WITHOUT entering the arena, so xterm's scroll always wins; we time
          // the press ourselves and fire the menu only on a stationary hold.
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: (_) => _cancelLongPress(),
            child: TerminalView(
              terminal,
              key: Key('terminal-view-${widget.sessionId}'),
              controller: _terminalController,
              scrollController: _scrollController,
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
