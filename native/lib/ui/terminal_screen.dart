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
import '../diagnostics/session_byte_recorder.dart';
import '../ssh/ssh_session.dart';
import '../state/sessions.dart';
import '../state/terminal_backend.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import '../terminal/url_hit_test.dart';
import 'compose_bar.dart';
import 'ghostty_terminal_view.dart';
import 'keybar.dart';
import 'session_menu.dart';
import 'url_action_overlay.dart';

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

/// Test-only counter: incremented each time a connect-path fit FORCE-RESYNCS
/// the remote PTY even though the LOCAL cols/rows did not change (#666). This
/// is the fix for first-connect-after-cold-launch: the remote attached at the
/// default size before layout, the local terminal is already correct, so the
/// only way to re-sync tmux is to push the size to the PTY directly (xterm
/// dedupes `terminal.resize` when unchanged). Reset it in test `setUp`.
@visibleForTesting
int debugForcedPtyResyncCount = 0;

/// Test-only counter: incremented each time an explicit fit (#659) is SKIPPED
/// because the body is OFFSTAGE (no mounted `TerminalViewState`, e.g. an
/// IndexedStack child for an inactive session) — #836. The fit does no useful
/// work offstage and its per-frame `[ui.fit659] no TerminalViewState yet`
/// ctrace line flooded the 200-event connect ring (~100×/sec), evicting the
/// real disconnect/state-transition events. We now skip the work every frame
/// but emit the ctrace line only ONCE per offstage period (see
/// `_offstageFitLogged`). This counter rises every skipped frame; the connect
/// log must NOT. Reset it in test `setUp`.
@visibleForTesting
int debugOffstageFitSkipCount = 0;

/// #570 — test hook. Set to the URL a long-press hit-test resolved (or null when
/// a long-press landed on no URL). Lets the on-emulator integration test assert
/// the tap→cell→URL path end to end without UI scraping. Reset in test `setUp`.
@visibleForTesting
String? debugLastHitUrl;

class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final composeBarVisible = ref.watch(composeBarVisibleProvider);
    final entries = sessions.entries;

    if (entries.isEmpty) {
      // Defensive: router should switch back to ConnectHomePage. Render a
      // placeholder rather than crashing if we ever land here mid-transition.
      return const Scaffold(body: Center(child: Text('No sessions')));
    }

    final activeEntry = sessions.active ?? entries.first;
    final activeIndex = entries.indexWhere((e) => e.id == activeEntry.id);

    // #790: point the byte/scroll recorder registry at the on-screen session so
    // the feedback overlay (which has no Riverpod scope of its own) snapshots the
    // RIGHT session's rings. All sessions are mounted in the IndexedStack, so
    // this — not each view's initState — is the single place that knows which is
    // foregrounded. The recorder itself is created lazily by each view.
    setActiveByteRecorder(activeEntry.id);

    // #573: keybar visibility is PER-SESSION — read the ACTIVE session's flag.
    // Switching sessions re-watches the new active id, so each session shows
    // its own keybar state; toggling one never affects another. The compose
    // bar's bottomReserve (below) consumes the same active-session value.
    final keybarVisible = ref.watch(
      sessionKeybarVisibleProvider(activeEntry.id),
    );

    // #653: resolve the active session's swatch color. Prefer the profile's
    // explicit color (seeded on connect); fall back to the session's terminal
    // theme accent (the palette cursor — mirrors the PWA `profileColor()`
    // theme-accent fallback). The cursor is always set, so the swatch is never
    // blank.
    final activePalette = ref.watch(
      sessionTerminalThemeProvider(activeEntry.id),
    );
    final swatchColor =
        ref.watch(sessionColorProvider(activeEntry.id)) ??
        activePalette.theme.cursor;

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
                  swatchColor: swatchColor,
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
                // #797: keys the per-session compose history ring so recalled
                // commands stay isolated to this session.
                sessionId: activeEntry.id,
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
    required this.swatchColor,
    required this.onSwipe,
    required this.composeOn,
    required this.onToggleCompose,
  });

  final String label;
  final int sessionCount;

  /// #653: the active session's profile color, shown as a small filled-circle
  /// swatch tag immediately left of the (centered) title. Resolved by the
  /// parent — the profile color when set, else the theme accent — so it is
  /// always a sensible color (never blank). Mirrors the PWA `session-dot`.
  final Color swatchColor;

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

  /// Logical-px horizontal inset reserved on each side of the centered title
  /// layer (#651) so the title — centered over the FULL bar width — clears the
  /// left menu icon/count and the right compose toggle and never collides with
  /// them. Symmetric so the title's center stays on the bar's center.
  static const double _titleSideInset = 48;

  Widget _buildBar(BuildContext context, ThemeData theme) {
    // #651/#653: the title (+ #653 swatch tag) is CENTERED across the full bar
    // width via a Stack overlay rather than sitting flush-left after the menu
    // icon (where it collided with the menu). The interactive controls — the
    // menu/swipe InkWell (left, full-width tap target) and the compose toggle
    // (right) — form the base layer; the centered title layer is wrapped in
    // IgnorePointer so taps fall through to the InkWell beneath it.
    return Material(
      key: const Key('session-bar'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Base layer: the menu/swipe tap target + the compose toggle.
          Row(
            children: [
              Expanded(
                child: InkWell(
                  // `session-menu-button` is retained as the stable terminal-
                  // screen-mounted marker smoke/integration tests poll for; it
                  // moved from the AppBar to the bottom bar. `session-bar-open-
                  // menu` is the screenshot/test-addressable name for the menu
                  // affordance.
                  key: const Key('session-bar-open-menu'),
                  onTap: () {
                    // Suppress the tap that fires at the tail of a swipe so a
                    // swipe-to-switch doesn't also pop the session menu (#568).
                    if (_swipeOccurred) {
                      _swipeOccurred = false;
                      return;
                    }
                    // Pass the bar's own height so the menu panel floats ABOVE
                    // the bar (not over it) — the last menu row no longer lands
                    // on the trigger, and a second tap on the trigger dismisses
                    // via the overlay barrier (owner 2026-06-01). `context` here
                    // is the _SessionBar element, so `context.size` is the bar's
                    // height.
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
                        // #607: hamburger with the session-count badge folded
                        // onto it (count moved LEFT). No expand_less up-arrow —
                        // session switching is left/right SWIPE (#568), so an
                        // "expand" affordance was misleading. The title moved
                        // OUT of this row into the centered overlay (#651).
                        _MenuIconWithCount(count: widget.sessionCount),
                      ],
                    ),
                  ),
                ),
              ),
              // #607: compose-bar toggle replaces the disconnect button.
              // Reflects on/off; disconnect now lives in the session menu.
              IconButton(
                key: const Key('session-bar-compose-toggle'),
                tooltip: widget.composeOn
                    ? 'Hide compose bar'
                    : 'Compose (swipe / voice)',
                isSelected: widget.composeOn,
                color: widget.composeOn ? theme.colorScheme.primary : null,
                // #615: tighter visual density so the IconButton's default 48px
                // tap box doesn't set the bar height; row padding drives it.
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.edit_note_outlined, size: 18),
                onPressed: widget.onToggleCompose,
              ),
            ],
          ),
          // Centered title layer (#651) + profile color swatch tag (#653).
          // IgnorePointer so the swipe/tap on the bar still reaches the base
          // InkWell. Padded symmetrically so the title centers over the whole
          // bar yet clears both controls.
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _titleSideInset),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // #653: profile color swatch — a small filled circle tag
                  // immediately left of the title. Color resolved by the
                  // parent (profile color, else theme accent). Mirrors the PWA
                  // `session-dot`.
                  Container(
                    key: const Key('session-bar-swatch'),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: widget.swatchColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
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

  /// #666: subscription to the proxy's `shellReady` stream — the
  /// PRODUCTION-reliable "the task-side shell now EXISTS" signal. The #659 arm
  /// hooked `sshShellProvider`, which (unlike the widget-test override) never
  /// resolves non-null in production — the real shell lives in the task isolate
  /// — so the connect burst was DEAD on device (the device log showed only
  /// `mount:`, never `connect:`/`burst:`). And a resize sent BEFORE the shell
  /// exists is dropped by `s.shell?.resize` (session_host.dart), so the
  /// mount-time re-sync (which fires ~10ms before shellReady) never reached the
  /// PTY. Arming off this stream fires the burst right when the shell exists, so
  /// the forced re-sync lands as a real SIGWINCH and tmux re-sizes. Re-fires on
  /// reconnect.
  StreamSubscription<void>? _shellReadySub;

  /// Last painter cell size we logged, used purely for a "font settled?"
  /// heuristic in the CTRACE659 line (the cell metrics stop changing once the
  /// bundled asset font is in effect). Null until the first fit attempt.
  Size? _lastLoggedCellSize;

  /// #836: latch so the offstage-skip ctrace line is emitted at most ONCE per
  /// offstage period. The fit path is driven per-frame (post-frame callbacks,
  /// `didChangeMetrics`, font changes, the connect burst); while the body is an
  /// inactive IndexedStack child there is no mounted `TerminalViewState`, so
  /// every one of those used to log `no TerminalViewState yet (offstage?)`
  /// (~100×/sec), flooding the 200-event connect ring and burying the real
  /// disconnect/state events. We still SKIP the fit each frame, but only log
  /// the skip once; the latch is cleared the moment a view IS found so a later
  /// offstage→onstage→offstage cycle is logged again.
  bool _offstageFitLogged = false;

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
      (_) => _scheduleExplicitFit('mount', force: true),
    );
    // #666: arm the connect re-fit on the proxy's shellReady stream — the
    // moment the task-side shell exists (so a forced re-sync is NOT dropped by
    // session_host's `s.shell?.resize`). This is the production-reliable signal
    // the sshShellProvider arm never delivered on device. The body mounts ~10ms
    // BEFORE shellReady on first connect, so subscribing here catches the event.
    for (final e in ref.read(sessionsProvider).entries) {
      if (e.id == widget.sessionId) {
        _shellReadySub = e.proxy.shellReady.listen((_) {
          if (!mounted) return;
          // Re-arm each shellReady (reconnect re-runs it); disarm first so the
          // burst actually re-fires rather than being skipped by the guard.
          _disarmConnectRemeasure();
          _armConnectRemeasure();
        });
        break;
      }
    }
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
  void _scheduleExplicitFit(String trigger, {bool force = false}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _explicitFit(trigger, force: force);
    });
  }

  void _explicitFit(String trigger, {bool force = false}) {
    if (!mounted) return;
    // The `terminal-view-$id` ValueKey is kept for test addressing, so we can't
    // also hang a `GlobalKey<TerminalViewState>` on the TerminalView. Locate its
    // state by descending our own element subtree instead.
    final state = _findTerminalViewState();
    if (state == null) {
      // #836: offstage (inactive IndexedStack child) — there is no mounted
      // TerminalViewState to measure, so the fit is pure churn. Always skip the
      // work, but emit the ctrace line ONLY ONCE per offstage period: the fit
      // path fires per-frame, so logging every skip floods the 200-event
      // connect ring (~100×/sec) and evicts the real disconnect/state events
      // (the symptom this issue reports). The latch is cleared as soon as a
      // view is found again (below), so a later offstage cycle re-logs.
      debugOffstageFitSkipCount += 1;
      if (!_offstageFitLogged) {
        _offstageFitLogged = true;
        ctrace('ui.fit659', '$trigger: no TerminalViewState yet (offstage?)');
      }
      return;
    }
    // A mounted view exists — re-arm the offstage latch so a future offstage
    // period is logged once more.
    _offstageFitLogged = false;
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
    var action = 'noop';
    if (changed) {
      // Drive the PTY-resize path directly. terminal.onResize (sessions.dart)
      // → proxy.sendResize → PTY. Pixel sizes mirror what xterm sends.
      terminal.resize(cols, rows, cell.width.round(), cell.height.round());
      debugExplicitFitAppliedCount += 1;
      action = 'RESIZED';
    } else if (force) {
      // Local size already correct, but the REMOTE PTY may be stale (#666):
      // on first-connect-after-cold-launch the initial PTY resize is sent at
      // the terminal's DEFAULT size before Flutter lays it out, so tmux
      // attaches at e.g. 80×24; the local terminal then lays out correctly
      // (55×51) but its size never changes again, so the prior guard re-sent
      // NOTHING — tmux stayed at 24 rows (status bar mid-screen, dead gap
      // below). Terminal.resize ALWAYS fires onResize (xterm 4.0.0
      // terminal.dart:362 — no dedupe) → proxy.sendResize → PTY, so re-sending
      // the SAME size re-syncs the remote without changing the local view. A
      // keyboard toggle / second connect did this incidentally; force makes it
      // deterministic. Only on connect-path triggers (mount/connect/burst) so
      // steady-state fits (metrics/font) don't spam PTY resizes.
      terminal.resize(cols, rows, cell.width.round(), cell.height.round());
      debugForcedPtyResyncCount += 1;
      action = 'RESYNC';
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
          '$action '
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
    // force: re-sync the PTY even when the local size is unchanged (#666 — the
    // remote may have attached at the stale default size).
    _scheduleExplicitFit('connect', force: true);
    // Staggered fits defeat the device font-settle race: at least one lands
    // after the cached asset font's metrics are in effect. 1200ms tail added
    // over #647 for slow cold-starts. force: same PTY re-sync rationale.
    for (final ms in const [120, 350, 700, 1200]) {
      _connectRemeasureTimers.add(
        Timer(
          Duration(milliseconds: ms),
          () => _explicitFit('burst-${ms}ms', force: true),
        ),
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

  /// #570: map a long-press to a buffer cell and, if it lands on a detected
  /// URL, show the Copy/Open action menu + a transient highlight over the URL's
  /// on-screen cell rects. [localPosition] is in the wrapping GestureDetector's
  /// coordinate space; we convert through GLOBAL coordinates into the
  /// RenderTerminal's own space so cell mapping is correct regardless of any
  /// padding/offset between the two render boxes.
  ///
  /// Cell mapping reuses xterm's PUBLIC `RenderTerminal.getCellOffset` (which
  /// already accounts for scroll offset + padding), so we never reimplement the
  /// layout math. The URL test reconstructs the logical line from the live
  /// buffer (url_hit_test.dart) and matches with the parser's regex.
  void _onTerminalLongPress(Terminal terminal, Offset localPosition) {
    // Mouse-reporting apps (vim/tmux/less with mouse ON) own the pointer; a tap
    // there is a click the app expects, not a URL probe. Skip so we never steal
    // the gesture from an interactive full-screen program (#570 conflict gate).
    if (terminal.mouseMode != MouseMode.none) {
      ctrace('ui.url570', 'skip — mouseMode=${terminal.mouseMode}');
      return;
    }
    final state = _findTerminalViewState();
    if (state == null) return;

    final CellOffset cell;
    final dynamic box;
    final Offset global;
    try {
      box = state.renderTerminal;
      if (!(box.attached as bool)) return;
      // GestureDetector localPosition → global → RenderTerminal-local.
      final renderObj = context.findRenderObject();
      global = renderObj is RenderBox
          ? renderObj.localToGlobal(localPosition)
          : localPosition;
      final local = box.globalToLocal(global) as Offset;
      cell = box.getCellOffset(local) as CellOffset;
    } catch (_) {
      return;
    }

    final hit = hitTestUrl(terminal, cell);
    debugLastHitUrl = hit?.url;
    ctrace(
      'ui.url570',
      'cell=(${cell.x},${cell.y}) hit=${hit?.url ?? "<none>"}',
    );
    if (hit == null || !mounted) return;

    // Compute the URL's on-screen cell rect(s). A soft-wrapped URL spans
    // multiple rendered rows, so we walk the logical-column range and emit one
    // GLOBAL rect per row segment via xterm's PUBLIC getOffset + cellSize.
    final rects = _urlHighlightRects(box, hit);

    showUrlActions(context, hit.url, highlightRects: rects, anchor: global);
  }

  /// Translate a [hit]'s logical-column range into GLOBAL on-screen rects, one
  /// per rendered buffer row the URL occupies. Uses xterm's PUBLIC
  /// `RenderTerminal.getOffset(CellOffset)` (cell top-left, RenderTerminal-local)
  /// + `cellSize`. Best-effort: wraps in try/catch so a layout race never throws.
  List<Rect> _urlHighlightRects(dynamic box, UrlHit hit) {
    final rects = <Rect>[];
    try {
      final cellSize = box.cellSize as Size;
      final width = hit.lineWidth > 0 ? hit.lineWidth : 1;
      for (var c = hit.logicalStart; c < hit.logicalEnd;) {
        final rowOffset = c ~/ width;
        final colInRow = c % width;
        final row = hit.logicalLineStartRow + rowOffset;
        // How many columns of this URL remain on this rendered row.
        final colsLeftOnRow = width - colInRow;
        final remaining = hit.logicalEnd - c;
        final span = remaining < colsLeftOnRow ? remaining : colsLeftOnRow;

        final topLeftLocal = box.getOffset(CellOffset(colInRow, row)) as Offset;
        final localRect = Rect.fromLTWH(
          topLeftLocal.dx,
          topLeftLocal.dy,
          cellSize.width * span,
          cellSize.height,
        );
        final globalTopLeft = (box as RenderBox).localToGlobal(
          localRect.topLeft,
        );
        rects.add(globalTopLeft & localRect.size);
        c += span;
      }
    } catch (_) {
      return rects;
    }
    return rects;
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
    _shellReadySub?.cancel();
    _disarmConnectRemeasure();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // #684: switchable terminal backend. The backend is read at BUILD time
    // (restart-to-apply) — when `ghostty`, render the flterm view instead of
    // xterm. The ghostty branch deliberately SKIPS the xterm-only machinery
    // (the #659 explicit-fit burst, #570 URL long-press, #617 mouse handler,
    // per-session theme/font): flterm self-fits, has native drag-select, and
    // per-session appearance parity is a deferred follow-up. The xterm path
    // (the `else` below) is the DEFAULT and stays unchanged.
    final backend = ref.watch(terminalBackendProvider);
    if (backend == TerminalBackend.ghostty) {
      return _buildGhosttyBody();
    }

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
    // #666: `ref.listen` does NOT fire for a value already present when the
    // listener is attached. On first-connect-after-cold-launch, RootRouter
    // mounts TerminalScreen only AFTER the session is `connected`, so the shell
    // can already be ready at this first build → the listener misses the
    // null→ready transition and the connect re-fit burst NEVER arms (the device
    // log showed only `mount:`, no `connect:`/`burst:`). Arm explicitly when we
    // observe a ready shell; `_armConnectRemeasure` is idempotent
    // (`_connectRemeasureArmed` guards re-entry), and a drop re-arms via the
    // listener's else branch above.
    if (shellAsync.valueOrNull != null) {
      _armConnectRemeasure();
    }
    // Per-session theme + font (#601, #571, #679): each session's TerminalView
    // reads ITS OWN palette + font size + font family, so two visible sessions
    // can differ.
    final fontSize = ref.watch(sessionFontSizeProvider(widget.sessionId));
    final fontFamily = ref.watch(sessionFontFamilyProvider(widget.sessionId));
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
          // #570: a LONG-PRESS GestureDetector wraps the TerminalView to probe
          // URL hit-testing → Copy/Open menu + highlight. Long-press is
          // deliberately the gesture: it does NOT compete with xterm's
          // vertical-drag scrollback (a pan, via the corrected wheel SGR — #617)
          // nor with tap/click mouse reporting, so the existing scroll path
          // stays unobstructed. `behavior: deferToChild` keeps the
          // TerminalView's own recognizers first in the arena — the long-press
          // only claims the pointer once the press-and-hold threshold passes,
          // after a drag would already have won. (NO wrapping Listener — that
          // was the #617 wheel-SGR regression source.)
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onLongPressStart: (details) =>
                _onTerminalLongPress(terminal, details.localPosition),
            child: TerminalView(
              terminal,
              key: Key('terminal-view-${widget.sessionId}'),
              scrollController: _scrollController,
              autofocus: false,
              padding: const EdgeInsets.all(4),
              theme: palette.theme,
              textStyle: TerminalStyle(
                fontSize: fontSize,
                // #679: per-session bundled font family. Falls back to the
                // default face for an un-customized session. `fontFamilyFallback`
                // keeps platform monospace coverage for glyphs the chosen face
                // is missing (and if the asset somehow isn't bundled).
                fontFamily: fontFamily,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// #684 — the ghostty (flterm) backend body. Keeps the shared disconnect
  /// banner (#624) so lifecycle feedback matches the xterm path, but mounts the
  /// flterm view (which owns its own I/O wiring + native drag-select). The
  /// xterm-only fit/URL/mouse machinery is intentionally absent here.
  Widget _buildGhosttyBody() {
    final sessionState =
        ref.watch(sessionDataProvider(widget.sessionId)).valueOrNull?.state ??
        SshSessionState.idle;
    return Column(
      children: [
        if (_isDisconnected(sessionState))
          _DisconnectBanner(state: sessionState),
        Expanded(child: GhosttyTerminalView(sessionId: widget.sessionId)),
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
