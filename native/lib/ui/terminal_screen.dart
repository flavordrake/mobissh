// Full-screen terminal screen — rendered when at least one SSH session is in
// `connected` state.
//
// Phase 2.A (#501): single session, one terminal view (flterm/libghostty since
// #684; the xterm.dart TerminalView fallback was removed in #1261).
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


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/detection_geom.dart';
import '../diagnostics/paint_stats.dart';
import '../diagnostics/session_byte_recorder.dart';
import '../ssh/ssh_session.dart';
import '../state/sessions.dart';
import '../state/terminal_providers.dart';
import '../state/ui_prefs_providers.dart';
import '../util/large_landscape.dart';
import 'compose_bar.dart';
import 'ghostty_terminal_view.dart';
import 'host_key_review.dart';
import 'keybar.dart';
import 'session_menu.dart';
import 'session_route_details.dart';
import 'update_banner.dart';

/// Minimum horizontal travel (logical px) before a drag on the session bar is
/// treated as a swipe-to-switch. Matches the ~50px threshold in the design so
/// a small horizontal wobble during a tap doesn't switch sessions.
const double kSessionSwipeThreshold = 50;

/// Vertical space (logical px) the bottom session bar occupies (#615). Single
/// source of truth shared by the compose-bar bottom reserve so a docked compose
/// panel always clears the bar. ~25% smaller than the old hardcoded 48 — the
/// bar's row padding was tightened to match (see `_SessionBar`).
const double kSessionBarReserve = 36;

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
    // Paint replay harness: same single place for the paint-stack counters, so
    // the bug report snapshots the ON-SCREEN session's boundary counters.
    setActivePaintStats(activeEntry.id);
    // #1072: same single place for the detection-geometry probe, so the bug
    // report snapshots the ON-SCREEN session's wash geometry.
    setActiveDetectionGeom(activeEntry.id);

    // #573: keybar visibility is PER-SESSION — read the ACTIVE session's flag.
    // Switching sessions re-watches the new active id, so each session shows
    // its own keybar state; toggling one never affects another. The compose
    // bar's bottomReserve (below) consumes the same active-session value.
    //
    // #1086: the STORED flag + the explicit-choice flag resolve (via
    // resolveKeybarVisible) to the value we actually render. On a large-landscape
    // surface a hardware keyboard is assumed, so a session the user hasn't
    // explicitly toggled hides the keybar by default; an explicit choice wins.
    final largeLandscape = isLargeLandscape(MediaQuery.sizeOf(context));
    final keybarVisible = resolveKeybarVisible(
      visible: ref.watch(sessionKeybarVisibleProvider(activeEntry.id)),
      explicit: ref.watch(sessionKeybarVisibleExplicitProvider(activeEntry.id)),
      largeLandscape: largeLandscape,
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
    // #566/#1086: the slim session bar — the thumb-reachable trigger for the
    // session menu (tap the label area) + a compose toggle at the right edge,
    // with a horizontal swipe across it switching sessions (#568). On a phone it
    // sits at the BOTTOM (below the keybar) so the menu sheet rises from
    // immediately above the affordance that summoned it. In large-landscape
    // (#1086) it moves to the TOP as a regular top menu (a hardware keyboard +
    // desktop-style chrome is assumed), and the terminal reclaims the bottom
    // space. Built once here so the swipe/compose wiring is identical either way.
    final sessionBar = _SessionBar(
      // #1086: on a tablet the bar is a COMPACT top-left indicator that drops
      // its menu DOWN from the top strip; on a phone it's the full-width
      // centered bottom bar. Same instance either way (only one `if` renders it).
      compact: largeLandscape,
      label: activeEntry.label,
      // #1189 (R16): a routed session's title carries the route glyph; a
      // direct session gets nothing. The hops come from the LIVE session, not
      // from the profile's (possibly since-edited) jumpIdentityKey.
      routeIcon: activeEntry.jumpHops.isEmpty
          ? null
          : SessionRouteIcon(
              key: const Key('session-route-icon'),
              entry: activeEntry,
            ),
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
        ref.read(sessionsProvider.notifier).setActive(entries[nextIndex].id);
        HapticFeedback.lightImpact();
      },
      composeOn: composeBarVisible,
      onToggleCompose: () =>
          ref.read(composeBarVisibleProvider.notifier).toggle(),
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // #1258: one-time "Update B available" snackbar over a session.
            const UpdateSessionOffer(),
            // The terminal + chrome column.
            Column(
              children: [
                // #1086: session controls at the TOP in large-landscape.
                if (largeLandscape) sessionBar,
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
                // #1086: on a phone the session bar stays at the BOTTOM, below
                // the keybar (unchanged phone layout).
                if (!largeLandscape) sessionBar,
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
                // here — when the chrome height changes. #1086: in large-landscape
                // the session bar moved to the TOP, so it no longer reserves any
                // bottom space.
                bottomReserve:
                    (largeLandscape ? 0 : kSessionBarReserve) +
                    (keybarVisible ? kKeybarReserve : 0),
                onClose: () =>
                    ref.read(composeBarVisibleProvider.notifier).set(false),
                // #1229: the same gate the terminal input path applies
                // (sessions.dart onOutput), plus the task's no-shell report.
                isLive: () {
                  final d = activeEntry.proxy.data;
                  return d.state == SshSessionState.connected &&
                      !d.inputNotSent;
                },
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
    required this.compact,
    required this.label,
    required this.sessionCount,
    required this.swatchColor,
    required this.onSwipe,
    required this.composeOn,
    required this.onToggleCompose,
    this.routeIcon,
  });

  /// #1086: tablet/large-landscape mode. When true the bar renders as a compact
  /// left-aligned cluster in the TOP menu strip and its session menu drops DOWN
  /// from the strip; when false it's the full-width centered phone bottom bar
  /// whose menu rises from the bottom.
  final bool compact;

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

  /// #1189: the tappable route glyph for a JUMPED session, built by the parent
  /// from the active entry's live hops. Null for a direct connection — which
  /// then gains no chrome at all.
  final Widget? routeIcon;

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
      child: widget.compact
          ? _buildCompactBar(context, theme)
          : _buildBar(context, theme),
    );
  }

  /// Open the session menu from this bar. On a phone (bottom bar) the panel
  /// rises ABOVE the bar; on a tablet (compact top strip) it drops DOWN from the
  /// strip (owner 2026-07-20: "menu should extend from the menu bar"). Suppresses
  /// the tap that fires at the tail of a swipe so swipe-to-switch (#568) doesn't
  /// also pop the menu. `context` is the _SessionBar element, so `context.size`
  /// is the bar's own height.
  void _openMenu(BuildContext context) {
    if (_swipeOccurred) {
      _swipeOccurred = false;
      return;
    }
    final barExtent = context.size?.height ?? 0;
    if (widget.compact) {
      showSessionMenu(context, topReserve: barExtent);
    } else {
      showSessionMenu(context, bottomReserve: barExtent);
    }
  }

  /// #607: compose-bar toggle at the bar's right edge (replaced disconnect,
  /// which moved into the session menu). Shared by both bar layouts.
  Widget _composeToggle(ThemeData theme) {
    return IconButton(
      key: const Key('session-bar-compose-toggle'),
      tooltip: widget.composeOn ? 'Hide compose bar' : 'Compose (swipe / voice)',
      isSelected: widget.composeOn,
      color: widget.composeOn ? theme.colorScheme.primary : null,
      // #615: tighter visual density so the IconButton's default 48px tap box
      // doesn't set the bar height; row padding drives it.
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.edit_note_outlined, size: 18),
      onPressed: widget.onToggleCompose,
    );
  }

  /// #1086: the compact TABLET bar — a left-aligned cluster (menu + count +
  /// swatch + label) in the top menu strip, with the compose toggle at the right
  /// edge. Unlike the phone bar there is no centered-title overlay: the label
  /// sits inline next to the menu affordance, anchored top-left ("session bar
  /// shrinks to top left", owner 2026-07-20). Same test keys as the phone bar.
  Widget _buildCompactBar(BuildContext context, ThemeData theme) {
    return Material(
      key: const Key('session-bar'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Flexible(
            child: InkWell(
              key: const Key('session-bar-open-menu'),
              onTap: () => _openMenu(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: Row(
                  key: const Key('session-menu-button'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MenuIconWithCount(count: widget.sessionCount),
                    const SizedBox(width: 12),
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
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // #1189: outside the menu InkWell so the glyph owns its own tap.
          if (widget.routeIcon != null) widget.routeIcon!,
          const Spacer(),
          _composeToggle(theme),
        ],
      ),
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
                  onTap: () => _openMenu(context),
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
              _composeToggle(theme),
            ],
          ),
          // Centered title layer (#651) + profile color swatch tag (#653).
          // IgnorePointer so the swipe/tap on the bar still reaches the base
          // InkWell. Padded symmetrically so the title centers over the whole
          // bar yet clears both controls.
          // #1189: only the swatch + label are IgnorePointer'd; the route glyph
          // sits beside them as a real tap target (an IgnorePointer over it
          // would make the whole affordance dead).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _titleSideInset),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: IgnorePointer(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // #653: profile color swatch — a small filled circle
                        // tag immediately left of the title. Color resolved by
                        // the parent (profile color, else theme accent).
                        // Mirrors the PWA `session-dot`.
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
                if (widget.routeIcon != null) widget.routeIcon!,
              ],
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

/// One session's terminal body: the #624 disconnect banner over the flterm
/// (libghostty) view, which owns its own I/O wiring, fit and drag-select.
/// #1261: the xterm.dart TerminalView fallback (and its #659 fit burst, #570
/// long-press URL probe and backend setting) was removed; ghostty had been the
/// default since #684.
class _SessionTerminalBody extends ConsumerWidget {
  const _SessionTerminalBody({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionData =
        ref.watch(sessionDataProvider(sessionId)).valueOrNull ??
        const SshSessionData();
    return Column(
      children: [
        if (_showBanner(sessionData))
          _DisconnectBanner(
            state: sessionData.state,
            inputNotSent: sessionData.inputNotSent,
            review: HostKeyReviewAction(
              sessionId: sessionId,
              data: sessionData,
              foregroundColor: Colors.white,
              onForget: (_) => forgetHostKeyAndRetrust(context, ref, sessionId),
            ),
          ),
        Expanded(child: GhosttyTerminalView(sessionId: sessionId)),
      ],
    );
  }
}

/// The banner shows for a dropped session, and also while typed input is being
/// dropped for lack of a shell (#1229) — that can happen in `connected`.
bool _showBanner(SshSessionData data) =>
    _isDisconnected(data.state) || data.inputNotSent;

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
  const _DisconnectBanner({
    required this.state,
    required this.inputNotSent,
    required this.review,
  });

  final SshSessionState state;

  /// #1229: typed input was dropped (no shell) — say so, persistently.
  final bool inputNotSent;

  /// #1235 Review action; renders nothing unless the failure is a CHANGED key.
  final Widget review;

  @override
  Widget build(BuildContext context) {
    final reconnecting =
        state == SshSessionState.reconnecting ||
        state == SshSessionState.softDisconnected;
    final text = inputNotSent
        ? 'Not connected — input not sent'
        : (reconnecting ? 'Disconnected — reconnecting…' : 'Disconnected');
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
          Flexible(child: review),
        ],
      ),
    );
  }
}
