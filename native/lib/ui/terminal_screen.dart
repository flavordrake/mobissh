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
// switches the active session (ring-wrap, haptic). The swipe handler lives on
// the bar (NOT the TerminalView) so it never steals the terminal's hardcoded
// vertical-scroll gesture.
// #617: the long-press selection context menu was REMOVED (owner: useless,
// didn't reliably select/copy). Removing it also drops the `Listener` wrapper
// that was a candidate for blocking the terminal's vertical scrollback drag.
// Paste stays available via the keybar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../diagnostics/connect_trace.dart';
import '../ssh/ssh_session.dart';
import '../state/sessions.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import 'compose_bar.dart';
import 'keybar.dart';
import 'session_menu.dart';

/// Minimum horizontal travel (logical px) before a drag on the session bar is
/// treated as a swipe-to-switch. Matches the ~50px threshold in the design so
/// a small horizontal wobble during a tap doesn't switch sessions.
const double kSessionSwipeThreshold = 50;

/// Vertical space (logical px) the bottom session bar occupies (#615). Single
/// source of truth shared by the compose-bar bottom reserve so a docked compose
/// panel always clears the bar. ~25% smaller than the old hardcoded 48 — the
/// bar's row padding was tightened to match (see `_SessionBar`).
const double kSessionBarReserve = 36;

/// Bundled monospace family declared in `pubspec.yaml` (#552). The xterm
/// `TerminalStyle.fontFamilyFallback` (platform monospace) covers glyphs the
/// bundled face is missing, so this stays robust even if the asset is absent.
const String kTerminalFontFamily = 'JetBrainsMono';

/// Test-only counter: incremented each time a session body ARMS the #659
/// connect-triggered fit burst (the shell-ready transition). Lets a widget test
/// prove the connect path — and ONLY the connect path, with no fonts/metrics
/// event — kicks off the explicit fit that on device fills the terminal without
/// a keyboard toggle. The actual device re-fit is gated by the on-emulator
/// integration test + owner validation (the headless harness can't reproduce
/// the stale-cell-size race). Reset it in test `setUp`.
@visibleForTesting
int debugConnectRemeasureArmCount = 0;

/// Test-only counter: incremented each time an explicit fit (#659) actually
/// CHANGES the terminal's view size — i.e. it computed cols/rows from the
/// rendered viewport + the painter cell metrics and drove `terminal.resize`
/// (which fires `onResize` → `proxy.sendResize` → PTY). Distinct from the arm
/// count: arming is "we tried", this is "the explicit resize moved the size".
/// Reset it in test `setUp`.
@visibleForTesting
int debugExplicitFitAppliedCount = 0;

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
    // resizeToAvoidBottomInset left at the DEFAULT (true): the body — including
    // the bottom session bar + keybar — lifts ABOVE the soft keyboard instead
    // of being covered by it. The #604 floating compose bar sets
    // resizeToAvoidBottomInset:false earlier, which had the side effect of the
    // keyboard COVERING the session bar (P0). #610 made the compose bar dock to
    // FIXED margins (it no longer chases the keyboard inset), so that override
    // is unnecessary AND harmful — removed. The bar now floats over the keyboard.
    return Scaffold(
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
                // Reserve the bottom chrome so a bottom-docked panel never hides
                // the session bar (#610). Heights are centralized constants
                // (#615): kSessionBarReserve (session bar) + kKeybarReserve
                // (keybar, only when visible). Update those — not magic numbers
                // here — when the chrome height changes.
                bottomReserve:
                    kSessionBarReserve + (keybarVisible ? kKeybarReserve : 0),
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
                // #615: vertical padding trimmed (was 8) to shrink the bar
                // ~25%. Pairs with the smaller compose toggle icon below.
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
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
            // #615: tighter visual density so the IconButton's default 48px
            // tap box doesn't set the bar height; the row padding now drives it.
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.edit_note_outlined, size: 18),
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
/// #617: the long-press context menu (and its `Listener`/`TerminalController`
/// selection plumbing) was removed. Selection stays entirely xterm.dart's
/// domain and the terminal's own vertical-scroll gesture is unobstructed, which
/// (with the #617 wheel-SGR fix) drives tmux scrollback.
class _SessionTerminalBody extends ConsumerStatefulWidget {
  const _SessionTerminalBody({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_SessionTerminalBody> createState() =>
      _SessionTerminalBodyState();
}

class _SessionTerminalBodyState extends ConsumerState<_SessionTerminalBody>
    with WidgetsBindingObserver {
  /// Passed to TerminalView so we own the scrollback Scrollable (#605). Having
  /// an explicit controller also lets future work jump-to-bottom on new output.
  final ScrollController _scrollController = ScrollController();

  /// True once the connect-triggered re-measure burst has been armed for the
  /// CURRENT live shell (#647). Reset when the shell goes away so a reconnect
  /// re-arms it. Prevents re-arming the burst on every rebuild while the
  /// session stays connected.
  bool _connectRemeasureArmed = false;

  /// Pending delayed fit timers from the connect burst (#659), tracked so they
  /// are cancelled on dispose and never fire against a gone widget.
  final List<Timer> _connectRemeasureTimers = <Timer>[];

  /// Last painter cell size we logged, used purely for a "font settled?"
  /// heuristic in the CTRACE659 line (the cell metrics stop changing once the
  /// bundled asset font is in effect). Null until the first fit attempt.
  Size? _lastLoggedCellSize;

  @override
  void initState() {
    super.initState();
    // #625/#600/#641/#647/#659 — terminal layout/resize correctness.
    //
    // xterm.dart's `RenderTerminal.performLayout` computes cols/rows from
    // `constraints.biggest / cellSize` and CACHES the result in `_viewportSize`;
    // its `_resizeTerminalIfNeeded` re-sends a PTY resize ONLY when that cached
    // size CHANGES. On the device's FIRST connect the first layout can run
    // before the bundled JetBrainsMono asset font has settled, so the cell size
    // is measured from the platform-monospace fallback and the terminal locks
    // in cols/rows for the WRONG cell size — the dead vertical gap above the
    // keybar (#625). It "settled" only after a relayout with a CHANGED
    // constraint (keyboard/rotation), which is why tapping to show the keyboard
    // fixed it.
    //
    // #641/#647 tried `markNeedsLayout`. That re-runs `performLayout` with the
    // SAME constraint → recomputes the SAME stale cell size → SAME cached
    // `_viewportSize` → NO-OP. Both shipped and FAILED on device.
    //
    // #659 stops relying on xterm's auto-measure. We compute cols/rows the same
    // way xterm does — but from the CURRENT render-object `size` + the painter's
    // `cellSize`, read in a post-frame so the asset font has had a frame to
    // settle — and drive `terminal.resize(cols, rows, cellW, cellH)` DIRECTLY.
    // `Terminal.resize` always fires `onResize` (→ `proxy.sendResize` → PTY,
    // wired in sessions.dart) and updates the terminal's view size, so it
    // bypasses the stale `_viewportSize` cache entirely. Mirrors the PWA's
    // explicit `fitAddon.fit()` on font/viewport change.
    WidgetsBinding.instance.addObserver(this);
    PaintingBinding.instance.systemFonts.addListener(_onSystemFontsChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scheduleExplicitFit('mount'),
    );
  }

  /// systemFonts listener — the bundled asset font finished loading. Re-fit so
  /// the now-correct cell metrics drive the PTY size (#641 path, #659 mechanism).
  void _onSystemFontsChanged() => _scheduleExplicitFit('font');

  /// Compute cols/rows from the CURRENT rendered viewport + painter cell metrics
  /// and drive `terminal.resize` directly when they differ from the terminal's
  /// current view size (#659). Deferred to a post-frame so it is safe to call
  /// from layout-phase notifications and so the render box has laid out.
  ///
  /// This is the REAL fix: it does not depend on xterm noticing a changed
  /// constraint (the #641/#647 markNeedsLayout no-op). It reads the truth off
  /// the render object and pushes it through the PTY-resize path itself. Every
  /// attempt logs a CTRACE659 line so a device failure yields DATA, not blind
  /// iteration.
  void _scheduleExplicitFit(String trigger) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _explicitFit(trigger);
    });
  }

  void _explicitFit(String trigger) {
    if (!mounted) return;
    // The `terminal-view-$id` ValueKey is kept for test addressing, so we can't
    // also hang a `GlobalKey<TerminalViewState>` on the TerminalView. Locate its
    // state by descending our own element subtree instead.
    final state = _findTerminalViewState();
    if (state == null) {
      ctrace('ui.fit659', '$trigger: no TerminalViewState yet (offstage?)');
      return;
    }
    // `RenderTerminal` is not exported from package:xterm, so the type is left
    // inferred. The getter throws if the viewport hasn't laid out yet (null
    // currentContext) and a detached box would also reject reads — either way a
    // later attempt in the burst recovers, so capture both inside the try.
    final Size size;
    final Size cell;
    try {
      final box = state.renderTerminal;
      if (!box.attached) {
        ctrace('ui.fit659', '$trigger: render box detached');
        return;
      }
      size = box.size;
      cell = box.cellSize;
    } catch (_) {
      ctrace('ui.fit659', '$trigger: render box not laid out yet');
      return;
    }
    final terminal = ref.read(terminalProvider(widget.sessionId));

    // Guard against a not-yet-measured cell (zero/NaN) which would blow up the
    // division and the PTY size.
    if (cell.width <= 0 || cell.height <= 0 || !size.width.isFinite) {
      ctrace(
        'ui.fit659',
        '$trigger: skip — bad metrics size=${_fmtSize(size)} '
            'cell=${_fmtSize(cell)}',
      );
      return;
    }

    // Compute cols/rows EXACTLY as xterm's `RenderTerminal._updateViewportSize`
    // does (xterm-4.0.0 render.dart): WIDTH uses the FULL box width (no padding
    // subtraction), HEIGHT subtracts the vertical padding only. Matching xterm
    // precisely is essential — a 1-cell disagreement would make our explicit
    // resize and xterm's auto-measure fight each other (endless churn). The
    // TerminalView padding is 4px on every edge (see the `padding` below), so
    // the vertical padding is 8px.
    const double pad = 4;
    final int cols = (size.width ~/ cell.width).clamp(1, 1 << 20);
    final int rows = ((size.height - pad * 2) ~/ cell.height).clamp(1, 1 << 20);

    final int curCols = terminal.viewWidth;
    final int curRows = terminal.viewHeight;
    final bool fontSettled =
        _lastLoggedCellSize != null && _lastLoggedCellSize == cell;
    _lastLoggedCellSize = cell;

    final bool changed = cols != curCols || rows != curRows;
    if (changed) {
      // Drive the PTY-resize path directly. terminal.onResize (sessions.dart)
      // → proxy.sendResize → PTY. Pixel sizes mirror what xterm sends.
      terminal.resize(cols, rows, cell.width.round(), cell.height.round());
      debugExplicitFitAppliedCount += 1;
    }

    // CTRACE659: the device-diagnosis line. Captures incoming render-box
    // constraints, the cell metrics xterm measured, the computed vs current
    // cols/rows, whether we drove a resize, and a font-settled heuristic.
    // Appears in the debug overlay, the on-device Connect log, AND the uploaded
    // feedback bundle (ctrace ring), so the owner's repro carries the data.
    ctrace(
      'ui.fit659',
      '$trigger: view=${_fmtSize(size)} cell=${_fmtSize(cell)} '
          'computed=${cols}x$rows cur=${curCols}x$curRows '
          '${changed ? "RESIZED" : "noop"} '
          'font=$kTerminalFontFamily settled=$fontSettled',
    );
  }

  static String _fmtSize(Size s) =>
      '${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)}';

  /// #659 — drive an explicit fit on FIRST CONNECT, without needing a keyboard
  /// toggle.
  ///
  /// On a real device's first connect NEITHER #641 trigger fires: the bundled
  /// JetBrainsMono asset is already cached (no `systemFonts` event) and there's
  /// no viewport change (no `didChangeMetrics`). The stale first-frame measure
  /// persisted until the user tapped to show the keyboard. We arm an explicit
  /// fit on the connect/shell-ready transition: once immediately, then again at
  /// a few short delays so at least one fires AFTER the asset font's cell
  /// metrics settle (the device race the emulator can't reproduce). Each fit is
  /// idempotent — it only drives `terminal.resize` when the computed cols/rows
  /// differ from the terminal's current view size. Armed once per live shell
  /// ([_connectRemeasureArmed]); re-arms after a drop so a reconnect repeats it.
  void _armConnectRemeasure() {
    if (_connectRemeasureArmed) return;
    _connectRemeasureArmed = true;
    // Test-only: lets a widget test assert the connect transition (and ONLY the
    // connect transition — no fonts/metrics event) armed the #659 fit burst.
    debugConnectRemeasureArmCount += 1;
    ctrace('ui.fit659', 'connect: arming fit burst (shell ready)');
    // Immediate (post-frame) fit — covers the case where layout is already
    // correct by connect time (e.g. the emulator / headless harness).
    _scheduleExplicitFit('connect');
    // Staggered fits defeat the device font-settle race: at least one lands
    // after the cached asset font's metrics are in effect. 1200ms tail added
    // over #647 for slow cold-starts.
    for (final ms in const [120, 350, 700, 1200]) {
      _connectRemeasureTimers.add(
        Timer(Duration(milliseconds: ms), () => _explicitFit('burst-${ms}ms')),
      );
    }
  }

  /// Drop the connect-fit arming + cancel pending burst timers so a reconnect
  /// re-arms the burst and gone timers never touch a dead widget.
  void _disarmConnectRemeasure() {
    _connectRemeasureArmed = false;
    for (final t in _connectRemeasureTimers) {
      t.cancel();
    }
    _connectRemeasureTimers.clear();
  }

  /// Walk this body's element subtree to find the xterm [TerminalViewState].
  /// Returns null before the first build or if the TerminalView isn't mounted
  /// (e.g. an offstage IndexedStack child that hasn't laid out yet).
  TerminalViewState? _findTerminalViewState() {
    TerminalViewState? found;
    void visit(Element el) {
      if (found != null) return;
      if (el is StatefulElement && el.state is TerminalViewState) {
        found = el.state as TerminalViewState;
        return;
      }
      el.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  /// Keyboard show/hide and rotation change the available terminal height. The
  /// Scaffold relayout already re-fits xterm in most cases, but we re-measure
  /// explicitly so a viewport change can never leave the PTY size stale vs. the
  /// rendered size (#600). Mirrors the PWA's visualViewport resize → re-fit.
  @override
  void didChangeMetrics() {
    _scheduleExplicitFit('metrics');
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_onSystemFontsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _disarmConnectRemeasure();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final terminal = ref.watch(terminalProvider(widget.sessionId));
    // #659 — arm the connect explicit-fit burst on the shell-ready transition.
    // `sshShellProvider` resolves to a non-null shell ONLY once the session
    // reaches `connected` (see terminal_providers.dart), so a ready AsyncData
    // here IS the first-connect / shell-ready signal. Listening (not just
    // watching) lets us fire the burst exactly on the transition and re-arm it
    // after a drop, without rebuilding the body. Each fit computes cols/rows
    // from the rendered viewport + cell metrics and drives terminal.resize —
    // bypassing xterm's stale auto-measure (the #641/#647 no-op).
    ref.listen(sshShellProvider(widget.sessionId), (prev, next) {
      if (next.valueOrNull != null) {
        _armConnectRemeasure();
      } else {
        // Shell went away (disconnect / reconnecting / loading) — re-arm for
        // the next connect so a reconnect gets the same first-connect re-fit.
        _disarmConnectRemeasure();
      }
    });
    final shellAsync = ref.watch(sshShellProvider(widget.sessionId));
    // Per-session theme + font (#601, #571): each session's TerminalView reads
    // ITS OWN palette + font size, so two visible sessions can differ.
    final fontSize = ref.watch(sessionFontSizeProvider(widget.sessionId));
    final palette = ref.watch(sessionTerminalThemeProvider(widget.sessionId));
    // #624: state-driven disconnect indicator. Reads the session lifecycle enum
    // directly (no parallel boolean — rules/state-management.md). The banner is
    // shown only for "was-live-then-dropped" states so it never flashes during
    // the initial connect handshake (idle/connecting/authenticating).
    final sessionState =
        ref.watch(sessionDataProvider(widget.sessionId)).valueOrNull?.state ??
        SshSessionState.idle;

    return Column(
      children: [
        if (_isDisconnected(sessionState))
          _DisconnectBanner(state: sessionState),
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
          // #617: no wrapping Listener/GestureDetector. The terminal's own
          // vertical-scroll gesture (xterm's alt-buffer scroll handler →
          // corrected wheel SGR via WheelFixMouseHandler) drives tmux
          // scrollback unobstructed. The long-press selection menu was removed.
          child: TerminalView(
            terminal,
            key: Key('terminal-view-${widget.sessionId}'),
            scrollController: _scrollController,
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

/// True when [state] is a "was-live-then-dropped" lifecycle state that warrants
/// a disconnect indicator (#624). Pre-first-connect states
/// (idle/connecting/authenticating/awaitingHostKey) and `connected` show no
/// banner — the banner means "this terminal is not live".
bool _isDisconnected(SshSessionState state) {
  switch (state) {
    case SshSessionState.softDisconnected:
    case SshSessionState.reconnecting:
    case SshSessionState.failed:
    case SshSessionState.disconnected:
      return true;
    case SshSessionState.idle:
    case SshSessionState.connecting:
    case SshSessionState.awaitingHostKey:
    case SshSessionState.authenticating:
    case SshSessionState.connected:
      return false;
  }
}

/// Slim, state-driven banner shown across the top of the terminal body when the
/// session is no longer live (#624). Distinct copy for reconnecting vs. fully
/// disconnected so the user knows whether the app is auto-retrying.
class _DisconnectBanner extends StatelessWidget {
  const _DisconnectBanner({required this.state});

  final SshSessionState state;

  @override
  Widget build(BuildContext context) {
    final reconnecting =
        state == SshSessionState.reconnecting ||
        state == SshSessionState.softDisconnected;
    final text = reconnecting ? 'Disconnected — reconnecting…' : 'Disconnected';
    return Container(
      key: const Key('terminal-disconnect-banner'),
      width: double.infinity,
      color: reconnecting ? Colors.orange.shade900 : Colors.red.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            reconnecting ? Icons.sync_problem : Icons.link_off,
            size: 14,
            color: Colors.white,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
