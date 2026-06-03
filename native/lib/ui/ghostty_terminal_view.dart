// Ghostty (flterm / libghostty-vt) session terminal view (#684, #582, #686).
//
// The OPT-IN alternate to the xterm.dart `TerminalView` rendered by
// `_SessionTerminalBody` in terminal_screen.dart. Selected via the persisted
// `terminalBackendProvider` (TerminalBackend.ghostty); the xterm path stays the
// default and is untouched.
//
// Why flterm: libghostty-vt gives NATIVE touch long-press select + copy, which
// xterm.dart v4 lacks (no selection-extend API — #582). This widget wires an
// flterm `TerminalController` to the SAME live session I/O the xterm path uses:
//
//   proxy.output (PTY bytes)        -> controller.write(bytes)
//   controller.onOutput (keystrokes)-> proxy.sendInput(bytes)   [gated: connected]
//   controller.onResize (cols,rows) -> proxy.sendResize(cols, rows)
//
// #686 polish (the device-tested v0.1.4 MVP rendered + selected but was rough):
//   1. Per-session FONT + SIZE parity with the xterm path. flterm carries the
//      font on `TerminalTheme` (fontFamily/fontSize/fontWeight), not a separate
//      textStyle — see [buildGhosttyTheme]. The view reads the SAME #679/#640
//      per-session providers the xterm body reads, so two visible sessions can
//      differ and a session defaults to the readable bundled JetBrainsMono face
//      (the prior hardcoded `TerminalTheme.dark()` 'JetBrains Mono' rendered
//      thin/unreadable on device).
//   2. SCROLL-vs-SELECT: a plain vertical drag must SCROLL the scrollback;
//      selection starts on LONG-PRESS. flterm's default `enabledSelections`
//      includes `drag` — see [kGhosttyScrollSettings] for why we drop it.
//   3. SELECTION endpoints / control: best achievable on flterm 0.0.3 — see the
//      "selection control" note below + a Select-All affordance.
//
// #688 fix (SWIPE STILL drag-selected after #686): the root cause was NOT
// `drag`. flterm restricts its pan/drag recognizer to `PointerDeviceKind.mouse`
// and its LONG-PRESS recognizer to `PointerDeviceKind.touch`
// (terminal_raw_gesture_detector.dart). Scroll comes from the inner `Scrollable`
// (terminal_view.dart), NOT flterm's gesture detector. On a finger SWIPE the
// brief start-of-swipe dwell makes flterm's `LongPressGestureRecognizer` win the
// arena; `onLongPressMoveUpdate` -> `_updateDrag` then paints a multi-line
// selection AND auto-scrolls. So `SelectionGesture.longPress` (which #686 KEPT)
// was the culprit, not `drag`. The owner wants swipe = scroll-ONLY; selection =
// DELIBERATE. We default to NO touch drag-select (`longPress` dropped) so a
// swipe only scrolls, and gate long-press-drag selection behind an explicit
// "select mode" toggle — see [kGhosttyScrollSettings] / [kGhosttySelectSettings]
// and `_selectMode`.
//
// #690 fix (SWIPE forwarded to the REMOTE as a mouse-button DRAG): distinct
// from #688's LOCAL selection. When the remote enables mouse mode (DECSET
// 1000/1002/1003/1006, e.g. tmux), flterm's `TerminalGestureDetector` forwards a
// finger swipe to the PTY as a button1 press+motion+release — a DRAG — which tmux
// reads as a mouse SELECTION (its own selection styling appears). flterm 0.0.3
// exposes NO interception hook analogous to xterm's `Terminal.mouseHandler` (the
// #617 fix): the report path is fully internal to its gesture detector,
// `TerminalGestureSettings` explicitly CANNOT disable mouse tracking, and the
// only built-in bypass (virtual Shift) leaks into key/scroll encoding and clears
// on the next keystroke. So we intercept ONE layer up — see
// [_PointerGestureRouter] / [ghosttySwipeShouldScrollLocally]. The wheel
// reports flterm emits for an actual scroll ARE correct (libghostty's own SGR
// wheel encoding, not xterm-4.0.0's buggy 68/69 — so no #617-style fix is needed
// for the wheel path here).
//
// #692 (DROP the #688 mode toggle — the GESTURE decides): the explicit select-
// mode toggle is gone. The pointer-absorbing overlay is now a gesture ROUTER:
//   - a finger SWIPE (movement first) -> scroll (the #690 path, unchanged);
//   - a deliberate LONG-PRESS (held stationary ~500ms) then drag -> SELECTION.
// We drive the selection OURSELVES rather than letting flterm forward it: flterm
// 0.0.3 does NOT export its pixel->cell mapping (`CellMetrics.cellAt`) or its
// internal mouse encoder, and libghostty's `MouseEncoder` is native FFI (not
// headless-testable) and not re-exported by flterm. So on a long-press-drag we
// synthesise SGR-1006 mouse reports — button1 press at the long-pressed cell,
// motion as the finger drags (deduped per cell), release on lift — and send them
// to the remote via `proxy.sendInput`. tmux then runs its OWN precise, native
// selection. The overlay is opaque while mouse tracking is on (so flterm never
// sees the raw touch), so the only mouse reports the remote gets are the ones WE
// emit: a swipe scrolls and reports nothing; a long-press-drag selects.
//
// Cell mapping is viewport-relative (1-based col;row), which is exactly what tmux
// mouse mode expects — and the overlay is active ONLY under mouse tracking, where
// flterm pins the viewport to the bottom (no scrollback offset to compensate).
//
// #705 (long-press-drag selection VANISHED on release): the #692 SGR path drove
// TMUX's selection, but tmux's default `MouseDragEnd1Pane` = copy-selection-and-
// cancel: on release tmux copies to ITS paste buffer and CLEARS the on-screen
// highlight, so the selection disappeared and our Copy button (which reads
// flterm's LOCAL selection via `controller.selectedText()`) got nothing. The fix
// is to drive flterm's OWN local selection instead of tmux's: on long-press we
// SET `controller.selection` (collapsed at the press cell) and on drag we extend
// its END (see [ghosttySelectionForCells]) — built viewport-relative then
// `.scroll(scrollbar.offset)` to absolute buffer rows, exactly as flterm's own
// `selectWord`/`selectLine`/`updateSelection` do. On release we do NOTHING, so
// the selection PERSISTS and `selectedText()` reads it. The long-press path no
// longer emits SGR mouse reports; the tap CLICK (#693) and swipe WHEEL (#702)
// SGR helpers are unchanged.
//
// #699 fix (selection landed several rows ABOVE the press): the cell map used to
// DERIVE the cell size from `overlayHeight / rows`, which is LARGER than flterm's
// real cell height (flterm sizes the grid to exactly `rows * realCellHeight` and
// leaves slack at the bottom), so dividing dy by it produced a row index too
// SMALL. flterm derives its cell height from the font's full typographic line
// height (`measureCellMetrics`, NOT exported), so we reproduce that measurement
// in [ghosttyMeasureCellSize] and map over the REAL cell size, subtracting the
// flterm `TerminalView` padding ([kGhosttyTerminalPadding]) the grid is offset
// by. The router instruments every gesture into the #699 gesture-trace ring
// (gesture_trace.dart) so a device repro carries the touch->cell numbers.
//
// #704 fix (app switch-away-and-back: terminal NOT refreshed AND NOT laid out):
// `_SessionTerminalBody` renders this view for the ghostty backend and skips the
// xterm-only resume machinery (the #659/#666 fit-burst, the `didChangeMetrics`
// re-fit), so on `AppLifecycleState.resumed` flterm neither re-fits nor repaints
// — stale/blank until a tap/scroll forces a frame, and tmux keeps its
// backgrounded grid. The fix listens for a transition INTO `resumed`
// ([ghosttyShouldRefreshOnLifecycle]) and, when connected: (1) RE-FITS by
// re-arming the SAME #702 forced-resize burst ([_armResizeResync]) so flterm
// re-lays-out and the PTY gets the current grid; (2) REFRESHES by nudging a
// repaint — `controller.scrollToBottom()` (pin to latest output, fire the scroll
// listener → frame) plus a post-frame `setState` so the repaint lands even if
// the buffer is unchanged. Both fire `ghostty-resume-refit`/`-refresh` into the
// connect/gesture trace so a device repro confirms they ran.
//
// SMART-SELECT (future, do NOT build here): a future button could select a word/
// path/URL UNIT at the tap — the PWA's `src/modules/selection.ts _selectableUnitAt`
// is the spec. The seam is [GhosttySelectionDriver] + [ghosttyCellForPosition]:
// resolve a unit's start/end cell, then drive press(start) -> motion(end) ->
// release to make tmux select that span. Not implemented in #692.
//
// flterm re-exports libghostty's `Key` input enum, which collides with
// Flutter's widget `Key`. We only use Flutter's, so hide flterm's.

import 'dart:async';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/gesture_trace.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../state/lifecycle_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import 'top_toast.dart';

/// The per-session [TerminalTheme] for the ghostty backend (#686, fix 1).
///
/// flterm carries font face + size on the THEME (`fontFamily`/`fontSize`), not a
/// separate `textStyle` like xterm.dart — changing either recalculates the
/// flterm cell metrics. We start from [TerminalTheme.dark] (Ghostty's Tomorrow
/// Night palette + the bundled emoji/mono fallback chain) and override the face
/// + size from the live #679/#640 per-session providers.
///
/// [family] is a pubspec-registered family id (e.g. `JetBrainsMono`) — the SAME
/// string the xterm path feeds `TerminalStyle.fontFamily`, and the same id
/// pubspec.yaml registers the bundled TTFs under, so flterm's
/// `FontDataResolver` finds the asset. Pure (no native libghostty .so), so it is
/// unit-testable headless.
TerminalTheme buildGhosttyTheme({
  required String family,
  required double fontSize,
}) {
  return TerminalTheme.dark().copyWith(fontFamily: family, fontSize: fontSize);
}

/// Gesture settings for the ghostty backend (#688, #692).
///
/// #686 dropped `SelectionGesture.drag` but a finger SWIPE STILL drag-selected
/// a multi-line block. Root cause: flterm gives `drag` to MOUSE pointers and
/// `longPress` to TOUCH pointers (terminal_raw_gesture_detector.dart), and on a
/// swipe the brief start-of-swipe dwell makes the touch `LongPressGestureRecognizer`
/// win the gesture arena — `onLongPressMoveUpdate` then paints a selection AND
/// auto-scrolls. So `longPress`, not `drag`, was the swipe culprit.
///
/// We drop BOTH `drag` and `longPress` here, leaving NO touch DRAG-select gesture
/// in flterm itself. Discrete taps still select (they never fire on a swipe), and
/// our own [_PointerGestureRouter] overlay handles touch long-press selection by
/// synthesising SGR mouse reports (#692) when the remote has mouse tracking on:
///
///   - vertical SWIPE -> SCROLL the scrollback (flterm's `Scrollable`), no select
///   - double-tap     -> select word   (discrete tap; never fires on a swipe)
///   - triple-tap     -> select line   (discrete tap; never fires on a swipe)
///   - Ctrl/Cmd+A     -> select all
///
/// #692 removed the #688 explicit select-mode toggle: a deliberate touch
/// long-press-drag now drives a remote (tmux) selection via the overlay, so no
/// flterm-native touch `longPress` is needed. `lineSelectMode.full` keeps line/
/// triple-tap selection grabbing the FULL row width (trailing blanks included).
const TerminalGestureSettings kGhosttyScrollSettings = TerminalGestureSettings(
  enabledSelections: {
    SelectionGesture.word,
    SelectionGesture.line,
    SelectionGesture.selectAll,
  },
  lineSelectMode: LineSelectMode.full,
);

/// Whether the pointer overlay should be ACTIVE — i.e. intercept touch so a
/// swipe scrolls locally and a long-press-drag drives a remote selection,
/// instead of letting flterm forward raw touch to the remote (#690, #692).
///
/// flterm forwards touch as mouse reports ONLY when the remote has mouse
/// tracking on (`mouseTracking != MouseTracking.none`, e.g. tmux mouse mode). A
/// plain shell with no mouse tracking is unaffected — flterm's own scroll/
/// selection works there, so the overlay stays inert. Pure (no FFI), so it's
/// unit-testable headless.
///
/// #692 dropped the `selectMode` parameter the #688 toggle added — the gesture,
/// not a mode, now decides scroll-vs-select.
bool ghosttySwipeShouldScrollLocally({required MouseTracking mouseTracking}) {
  return mouseTracking != MouseTracking.none;
}

/// Whether a FORCED post-shellReady PTY resize re-sync should be sent for the
/// ghostty backend (#702).
///
/// The xterm path's #666/#659 connect fit-burst (`[ui.fit659]` in
/// terminal_screen.dart) is XTERM-ONLY: it hunts for xterm.dart's
/// `TerminalViewState`, which is offstage on the ghostty backend, so the burst
/// NEVER runs and the only PTY resize is the one fired BEFORE `shellReady` — the
/// classic #666 drop (`s.shell?.resize` discards a resize sent before the shell
/// exists). tmux then keeps the stale pre-shellReady size and the first-connect
/// layout is wrong.
///
/// The ghostty view already wires `controller.onResize → proxy.sendResize` and
/// mirrors `_cols`/`_rows`, but flterm only emits `onResize` when its computed
/// grid CHANGES — so if the first layout equals the pre-shellReady size, nothing
/// re-fires after the shell is actually ready. This helper gates a Ghostty-LOCAL
/// forced re-send: on `shellReady` (and a short follow-up burst) we re-send the
/// CURRENT grid even if unchanged, so tmux gets the real size AFTER the shell
/// exists. Guard: only when the session is [connected] and [cols]/[rows] are a
/// valid (> 0) grid (flterm may not have laid out yet at the exact shellReady
/// instant). Pure (no FFI / no widget) → unit-testable headless.
bool ghosttyShouldResyncResize({
  required bool connected,
  required int cols,
  required int rows,
}) {
  return connected && cols > 0 && rows > 0;
}

/// The delayed re-sync ticks (ms after `shellReady`) for the ghostty
/// first-connect resize burst (#702), mirroring the xterm #659/#666 burst
/// (120/350/700/1200ms). flterm may not have laid out its real grid at the exact
/// `shellReady` instant, so we re-send at a few delays until [_cols]/[_rows] are
/// valid — at least one tick lands after flterm's grid settles. Each tick is
/// guarded by [ghosttyShouldResyncResize], so a tick with no valid grid is a
/// no-op (no stray resize).
const List<int> kGhosttyResyncBurstMs = [120, 350, 700, 1200];

/// Whether an app-lifecycle transition warrants a Ghostty resume re-fit +
/// refresh (#704).
///
/// On app switch-away-and-back the flterm view neither re-fits nor repaints —
/// `_SessionTerminalBody` (terminal_screen.dart) renders [GhosttyTerminalView]
/// for the ghostty backend and DELIBERATELY skips the xterm-only resume
/// machinery (the #659/#666 fit-burst, the `didChangeMetrics` re-fit). So on
/// `AppLifecycleState.resumed` flterm shows stale/blank content until a tap or
/// scroll forces a frame, and the PTY (tmux) keeps whatever grid it had while
/// backgrounded.
///
/// This gates the resume action on a transition INTO `resumed` from a
/// non-resumed state ([AppLifecycleState.paused]/`inactive`/`hidden`/`detached`,
/// or a null first-listen). A `resumed → resumed` repeat (a spurious provider
/// tick) is a no-op so the burst doesn't double-fire, and any transition INTO a
/// non-resumed state (e.g. → paused) is ignored. Pure (no FFI / no widget) →
/// unit-testable headless.
bool ghosttyShouldRefreshOnLifecycle(
  AppLifecycleState? prev,
  AppLifecycleState next,
) {
  if (next != AppLifecycleState.resumed) return false;
  return prev != AppLifecycleState.resumed;
}

/// The padding flterm's [TerminalView] is built with (`EdgeInsets.all(4)`), in
/// logical px (#699). flterm wraps its `Scrollable` + render box in a
/// `Padding(padding: widget.padding)`, so the grid's top-left is offset by this
/// much from the overlay origin. The touch->cell map MUST subtract it or every
/// row/col is shifted toward the origin. Kept in sync with the literal in
/// [GhosttyTerminalView.build]'s `TerminalView(padding: ...)`.
const double kGhosttyTerminalPadding = 4.0;

/// The REAL per-cell pixel size flterm renders at, for the touch->cell map
/// (#699). This is the ROOT-CAUSE fix: flterm derives its cell height from the
/// font's full typographic line height (`measureCellMetrics`: the height of
/// `Mgj`, ceil-snapped to the device pixel grid), NOT from `viewportH/rows`.
///
/// flterm 0.0.3 does NOT export `CellMetrics`/`measureCellMetrics` (its public
/// `flterm.dart` exports only the widgets/theme/gesture types), and the render
/// box is private — so we cannot read flterm's geometry directly. Instead we
/// reproduce its EXACT measurement here with the same `TextPainter` reference
/// glyphs ('M' advance for width, 'Mgj' height for height) and the same
/// ceil-to-device-pixel snapping, so our mapping uses the cell size flterm
/// actually laid the grid out with. Pure Flutter (no FFI) → headless-testable.
///
/// [devicePixelRatio] snaps to the same grid flterm uses; default 1.0 keeps the
/// pure unit tests deterministic. [fontFamilyFallback] mirrors the theme's
/// fallback chain so width measurement matches the rendered face.
Size ghosttyMeasureCellSize({
  required double fontSize,
  required String fontFamily,
  FontWeight fontWeight = FontWeight.normal,
  List<String>? fontFamilyFallback,
  double devicePixelRatio = 1.0,
}) {
  final dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
  final style = TextStyle(
    fontSize: fontSize,
    fontFamily: fontFamily,
    fontWeight: fontWeight,
    fontFamilyFallback: fontFamilyFallback,
  );

  final widthPainter = TextPainter(
    text: TextSpan(text: 'M', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final faceWidth = widthPainter.width;
  widthPainter.dispose();

  // 'Mgj' exercises ascenders + descenders so the height is the full
  // typographic line extent — exactly what flterm's measureCellMetrics uses.
  final vertPainter = TextPainter(
    text: TextSpan(text: 'Mgj', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final faceHeight = vertPainter.height;
  vertPainter.dispose();

  double ceilToDevicePixel(double value) => (value * dpr).ceilToDouble() / dpr;

  return Size(ceilToDevicePixel(faceWidth), ceilToDevicePixel(faceHeight));
}

/// Map a touch pixel position within the terminal viewport to a 1-based
/// (col, row) terminal cell for SGR mouse reports (#692, fixed #699).
///
/// [dx]/[dy] are the raw overlay-local touch coords. [cellWidth]/[cellHeight]
/// are the REAL flterm cell size (see [ghosttyMeasureCellSize]). [padding] is
/// the flterm `TerminalView` padding to subtract (the grid is offset by it).
/// [cols]/[rows] are the live grid dimensions (from `controller.onResize`),
/// used only to CLAMP the result into `[1, cols] x [1, rows]` so an edge or
/// out-of-range touch never produces an off-grid report.
///
/// #699 root cause: the old map used `cellHeight = overlayHeight / rows`, which
/// is LARGER than flterm's real cell height (flterm sizes the grid to exactly
/// `rows * realCellHeight` and leaves slack at the bottom), so dividing dy by it
/// produced a row index that was too SMALL — the selection landed several rows
/// ABOVE the press. Using the real cell height + subtracting the padding maps a
/// touch to the cell directly under the finger.
///
/// Viewport-relative (no scrollback offset): the overlay is active only under
/// mouse tracking, where flterm pins the viewport to the bottom — exactly the
/// coordinate space tmux mouse mode expects. Pure (no FFI) → unit-testable.
(int col, int row) ghosttyCellForPosition({
  required double dx,
  required double dy,
  required double cellWidth,
  required double cellHeight,
  required int cols,
  required int rows,
  double padding = kGhosttyTerminalPadding,
}) {
  if (cols <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0) {
    return (1, 1);
  }
  final innerDx = dx - padding;
  final innerDy = dy - padding;
  final col = (innerDx / cellWidth).floor() + 1;
  final row = (innerDy / cellHeight).floor() + 1;
  return (col.clamp(1, cols), row.clamp(1, rows));
}

/// Build the flterm LOCAL [TerminalSelection] for a touch long-press-drag, in
/// flterm's coordinate space, from VIEWPORT-relative 1-based start/end cells
/// (#705).
///
/// #705 root cause: the #692 long-press path synthesised SGR-1006 mouse reports
/// so tmux ran its OWN selection. But tmux's default `MouseDragEnd1Pane` =
/// `copy-selection-and-cancel`: on release tmux copies to ITS paste buffer and
/// CLEARS the on-screen highlight — so the selection VANISHES on lift and our
/// Copy button (which reads flterm's LOCAL selection via
/// `controller.selectedText()`) gets nothing. The fix is to drive flterm's OWN
/// local selection instead: set `controller.selection` to the span below, which
/// PERSISTS after release, and `selectedText()` then reads it.
///
/// Coordinate model (mirrors flterm's `selectLine`/`selectWord`/`updateSelection`
/// in terminal_controller_impl.dart, which build a viewport-relative
/// `TerminalSelection` then `.scroll(scrollbar.offset)`):
///   - [ghosttyCellForPosition] returns 1-based VIEWPORT col/row; flterm's
///     `TerminalSelection` is 0-based, so subtract 1 from each.
///   - rows are ABSOLUTE buffer rows = viewport row + [scrollOffset]
///     (`controller.scrollbar.offset`); we apply that here via `.scroll`.
///   - `endCol` is EXCLUSIVE in flterm's text extraction (`selectedText` uses
///     `bottomCol - 1`), so to make the dragged END cell INCLUSIVE we set
///     `endCol = endViewCol` (the 1-based value == 0-based end + 1). The anchor
///     `startCol` is the 0-based start cell (inclusive top).
///
/// A collapsed press (start == end cell) yields a zero/one-cell selection that
/// `selectedText()` returns empty for until the finger drags — exactly the
/// "press anchors, drag grows the highlight" feel. Pure (no FFI / no widget) so
/// the conversion is unit-testable headless.
TerminalSelection ghosttySelectionForCells({
  required int startViewCol,
  required int startViewRow,
  required int endViewCol,
  required int endViewRow,
  required int scrollOffset,
}) {
  // Viewport-relative, 0-based anchor; end col stays 1-based so flterm's
  // exclusive `bottomCol` includes the dragged cell. Then shift to absolute
  // buffer rows by the scrollback offset, mirroring flterm's own builders.
  return TerminalSelection(
    startRow: startViewRow - 1,
    startCol: startViewCol - 1,
    endRow: endViewRow - 1,
    endCol: endViewCol,
  ).scroll(scrollOffset);
}

/// SGR-1006 button1-PRESS report at the 1-based ([col], [row]) cell (#692).
///
/// `CSI < 0 ; col ; row M` — button 0 (left), uppercase `M` = press.
String ghosttySgrMousePress({required int col, required int row}) =>
    '\x1b[<0;$col;${row}M';

/// SGR-1006 button1-MOTION (drag) report at ([col], [row]) (#692).
///
/// `CSI < 32 ; col ; row M` — 32 is the motion bit added to button 0, so this is
/// "left button held, pointer moved" — what tmux reads as extending a selection.
String ghosttySgrMouseMotion({required int col, required int row}) =>
    '\x1b[<32;$col;${row}M';

/// SGR-1006 button1-RELEASE report at ([col], [row]) (#692).
///
/// `CSI < 0 ; col ; row m` — lowercase `m` = release; ends the tmux selection.
String ghosttySgrMouseRelease({required int col, required int row}) =>
    '\x1b[<0;$col;${row}m';

/// Drives a remote terminal selection by emitting SGR-1006 mouse reports for a
/// touch long-press-drag (#692).
///
/// flterm 0.0.3 doesn't expose its pixel->cell mapping or its native mouse
/// encoder, and libghostty's `MouseEncoder` is native FFI (not headless-
/// testable), so we synthesise the reports ourselves and hand them to
/// [onReport] (wired to `proxy.sendInput`). The remote (tmux) then runs its own
/// precise, native selection:
///
///   - [press]   once at the long-pressed start cell (button1 down);
///   - [motion]  on each NEW cell as the finger drags (deduped — only on cell
///     change, to avoid flooding the PTY);
///   - [release] on lift (button1 up) at the last cell.
///
/// Robust to out-of-order calls: [motion]/[release] before a [press] are no-ops
/// (no stray reports), and a fresh [press] after [release] starts a new
/// selection. Pure (no FFI), so the state machine is unit-testable headless.
class GhosttySelectionDriver {
  GhosttySelectionDriver({required this.onReport});

  /// Sink for each synthesised SGR report (wired to `proxy.sendInput`).
  final void Function(String report) onReport;

  int? _col;
  int? _row;
  bool _active = false;

  /// Begin a selection: button1-down at ([col], [row]).
  void press({required int col, required int row}) {
    _active = true;
    _col = col;
    _row = row;
    onReport(ghosttySgrMousePress(col: col, row: row));
  }

  /// Extend the selection to ([col], [row]) — only reports on a cell change.
  void motion({required int col, required int row}) {
    if (!_active) return;
    if (col == _col && row == _row) return;
    _col = col;
    _row = row;
    onReport(ghosttySgrMouseMotion(col: col, row: row));
  }

  /// End the selection: button1-up at the last cell. No-op if not active.
  void release() {
    if (!_active) return;
    final col = _col;
    final row = _row;
    _active = false;
    _col = null;
    _row = null;
    if (col == null || row == null) return;
    onReport(ghosttySgrMouseRelease(col: col, row: row));
  }

  /// A discrete CLICK at ([col], [row]) — button1 press THEN release at the
  /// SAME cell, with no motion in between (#693).
  ///
  /// This is what a TAP forwards under remote mouse mode so tmux selects the
  /// clicked status-bar window / pane (the long-press path drives a DRAG
  /// selection; a tap is a plain click). Implemented in terms of [press] +
  /// [release] so it reuses the same state machine and emits exactly two
  /// reports: `CSI<0;col;rowM` then `CSI<0;col;rowm`.
  void click({required int col, required int row}) {
    press(col: col, row: row);
    release();
  }
}

/// The SGR-1006 reports a discrete TAP forwards as a CLICK at the 1-based
/// ([col], [row]) cell (#693): button1 press THEN release at the SAME cell, no
/// motion. Pure (no FFI / no driver state), so the byte sequence + order are
/// unit-testable headless. Mirrors [GhosttySelectionDriver.click] exactly.
List<String> ghosttyTapClickReports({required int col, required int row}) => [
  ghosttySgrMousePress(col: col, row: row),
  ghosttySgrMouseRelease(col: col, row: row),
];

/// Whether a TAP at the terminal should forward an SGR mouse CLICK to the
/// remote (#693).
///
/// A tap forwards a click ONLY when the gesture router overlay is [active] —
/// i.e. the remote has mouse tracking on (tmux mouse mode), where a click maps
/// to "select this window/pane". In a plain shell (overlay inert) a tap just
/// focuses + raises the keyboard and emits NO SGR bytes (so escape bytes never
/// land as literal text). Pure, so the gating decision is unit-testable.
bool ghosttyTapShouldForwardClick({required bool active}) => active;

/// Map a vertical swipe DELTA (logical px the finger moved this update) to a
/// scrollback pixel delta to apply to the [TerminalScrollController] (#690).
///
/// A finger dragging DOWN (positive dy) reveals OLDER content, i.e. scrolls the
/// viewport UP toward smaller pixel offsets — so the scroll delta is the
/// negation of the finger delta, matching a natural touch-scroll. Pure.
double ghosttyScrollDeltaForSwipe(double fingerDy) => -fingerDy;

/// SGR-1006 WHEEL-UP report at the 1-based ([col], [row]) cell (#693).
///
/// `CSI < 64 ; col ; row M` — button 64 is the wheel-up code. tmux's DEFAULT
/// root-table binding `bind -n WheelUpStatus previous-window` switches to the
/// PREVIOUS window when a wheel-up lands on the status line (no prefix, no user
/// config). So a horizontal swipe LEFT (→ previous-window) synthesises this at
/// the status row. Pure (no FFI), so the byte sequence is unit-testable headless.
String ghosttySgrWheelUp({required int col, required int row}) =>
    '\x1b[<64;$col;${row}M';

/// SGR-1006 WHEEL-DOWN report at the 1-based ([col], [row]) cell (#693).
///
/// `CSI < 65 ; col ; row M` — button 65 is the wheel-down code. tmux's DEFAULT
/// root-table binding `bind -n WheelDownStatus next-window` switches to the NEXT
/// window when a wheel-down lands on the status line. So a horizontal swipe RIGHT
/// (→ next-window) synthesises this at the status row. Pure (no FFI), so the byte
/// sequence is unit-testable headless.
String ghosttySgrWheelDown({required int col, required int row}) =>
    '\x1b[<65;$col;${row}M';

/// The window-switch direction a horizontal swipe maps to (#693).
///
/// Mobile-natural convention: a swipe LEFT advances to the NEXT window (the
/// content slides left to reveal what's "ahead"); a swipe RIGHT goes to the
/// PREVIOUS window. A swipe below threshold does nothing.
enum GhosttyWindowSwitch {
  /// Below the px threshold — no window step.
  none,

  /// Swipe RIGHT (dx ≥ +threshold) → next-window via a wheel-DOWN report
  /// (`WheelDownStatus`).
  next,

  /// Swipe LEFT (dx ≤ -threshold) → previous-window via a wheel-UP report
  /// (`WheelUpStatus`).
  previous,
}

/// Decide whether a horizontal swipe of net [totalDx] logical px (across the
/// whole drag) crosses [threshold] and, if so, in which direction (#693).
///
/// Direction convention (owner-chosen 2026-06-03 — swiped to match the keybar's
/// tab feel):
///   - swipe RIGHT (`totalDx >=  threshold`) → [GhosttyWindowSwitch.next]
///     (next-window, emitted as wheel-DOWN → `WheelDownStatus`);
///   - swipe LEFT  (`totalDx <= -threshold`) → [GhosttyWindowSwitch.previous]
///     (previous-window, emitted as wheel-UP → `WheelUpStatus`);
///   - otherwise → [GhosttyWindowSwitch.none].
///
/// ONE discrete step per swipe — the caller emits a single wheel report, never a
/// stream. Pure (no FFI), so the thresholds/directions are unit-testable headless.
GhosttyWindowSwitch ghosttyWindowSwitchForSwipe(
  double totalDx,
  double threshold,
) {
  if (totalDx <= -threshold) return GhosttyWindowSwitch.previous;
  if (totalDx >= threshold) return GhosttyWindowSwitch.next;
  return GhosttyWindowSwitch.none;
}

/// The default horizontal-swipe distance (logical px) that triggers ONE window
/// step (#693). Chosen in the ~24–48px band: large enough that a near-vertical
/// scroll's incidental horizontal drift never trips a window switch, small
/// enough for a comfortable one-thumb flick.
const double kGhosttyWindowSwitchThreshold = 32.0;

/// The 1-based status-line row a window-switch wheel report targets (#693).
///
/// tmux's `WheelUpStatus`/`WheelDownStatus` fire when the wheel lands on the
/// STATUS-LINE row. The default status position is BOTTOM, so the status row is
/// the last grid row, [rows]. (CAVEAT: if the user sets `status-position top`
/// the status row would be 1 — out of scope for #693; see the file TRACE.)
/// Column is irrelevant to the status binding; we use 1. Pure.
(int col, int row) ghosttyStatusRowCell({required int rows}) => (1, rows);

/// A gesture ROUTER overlay that absorbs touch and disambiguates a SWIPE from a
/// deliberate LONG-PRESS (#690, #692).
///
/// Active only while [active] is true (see [ghosttySwipeShouldScrollLocally] —
/// i.e. the remote has mouse tracking on). Routes:
///   - a VERTICAL finger SWIPE -> SCROLL the [scrollController] directly (flterm
///     then emits canonical wheel reports), so the swipe NEVER reaches the remote
///     as a button drag (#690);
///   - a HORIZONTAL finger SWIPE -> switch the tmux WINDOW (#693): on lift, if the
///     net dx crossed [kGhosttyWindowSwitchThreshold], emit ONE SGR wheel report
///     at the status-line row via [onMouseReport] — tmux's default
///     `WheelUpStatus`/`WheelDownStatus` binding steps one window (swipe RIGHT →
///     next, swipe LEFT → previous);
///   - a deliberate LONG-PRESS (held stationary past the recogniser threshold)
///     then drag -> drive flterm's LOCAL SELECTION (#705): map the touch -> cell
///     and set/extend `controller.selection` via [onSelectionStart]/
///     [onSelectionExtend]. The selection PERSISTS after release (unlike the
///     #692 SGR-tmux path, where tmux's default `copy-selection-and-cancel`
///     cleared the highlight on lift and left Copy with nothing), so the Copy
///     button's `selectedText()` reads it.
///
/// The gesture arena disambiguates for us: a vertical-ish swipe wins the vertical
/// recogniser (scroll); a horizontal-ish swipe wins the horizontal one (window
/// switch); if the finger HOLDS first the long-press recogniser wins (select).
///
/// Why OPAQUE (when active), not translucent: flterm reports tracked mouse via a
/// raw `Listener` (onPointerDown/Move/Up), which is NOT a gesture-arena
/// participant — so merely WINNING the arena would not stop flterm from also
/// emitting button press/motion on the same pointer. The only way to keep the
/// touch off flterm's `Listener` is to be the opaque hit-test target so the
/// pointer never reaches the terminal below. Because that also swallows taps, the
/// active branch handles the tap itself: it raises the keyboard via [onTap] AND
/// forwards an SGR button1 CLICK at the tapped cell via [onMouseReport] (#693) so
/// tmux selects the clicked status-bar window / pane.
///
/// When [active] is false (mouse mode off) the overlay is a TRANSLUCENT tap layer
/// (#693), NOT inert: flterm's gesture detector calls only `requestFocus()` on a
/// tap (never `showKeyboard()`), so a tap on a plain shell never raised the
/// Android IME. The translucent layer (`HitTestBehavior.translucent`) lets the
/// pointer fall THROUGH to flterm (its own focus/scroll/selection still run)
/// while a top-level tap recogniser additionally raises the keyboard via [onTap].
/// In the inactive branch NO SGR is emitted — a plain-shell tap only focuses +
/// raises the keyboard.
class _PointerGestureRouter extends StatefulWidget {
  const _PointerGestureRouter({
    required this.active,
    required this.scrollController,
    required this.cols,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
    required this.mouseTrackingLabel,
    required this.onTap,
    required this.onFocus,
    required this.onMouseReport,
    required this.onSelectionStart,
    required this.onSelectionExtend,
  });

  /// Whether to intercept touch (the remote has mouse tracking on).
  final bool active;

  /// The SAME controller handed to the flterm [TerminalView] — moving it routes
  /// through flterm's `_onScrollChanged` → wheel reports / local scroll.
  final TerminalScrollController scrollController;

  /// Live grid columns/rows (from `controller.onResize`) for pixel->cell mapping.
  final int cols;
  final int rows;

  /// The REAL flterm cell size (logical px), measured by [ghosttyMeasureCellSize]
  /// from the live theme font (#699). The touch->cell map divides by THIS, not by
  /// `overlayHeight/rows` — the #699 root-cause fix.
  final double cellWidth;
  final double cellHeight;

  /// The live `MouseTracking` state name, recorded into each gesture-trace line
  /// (#699) so a device repro shows whether mouse mode was on when the offset
  /// occurred.
  final String mouseTrackingLabel;

  /// Invoked on a tap to FOCUS + raise the soft keyboard (#693). flterm's own
  /// tap only calls `requestFocus()`, which doesn't show the Android IME, so the
  /// parent wires this to `requestFocus()` + `controller.showKeyboard()`. Fires
  /// in BOTH the active (opaque) and inactive (translucent) branches.
  final VoidCallback onTap;

  /// Invoked to FOCUS only (no keyboard) on a long-press-start — so a deliberate
  /// selection gesture doesn't pop the soft keyboard over the text being
  /// selected. A plain TAP still raises the keyboard via [onTap].
  final VoidCallback onFocus;

  /// Sink for synthesised SGR mouse reports (wired to `proxy.sendInput`). Used
  /// under mouse mode for the tap CLICK (#693). NO LONGER used for the long-
  /// press selection — that drives flterm's LOCAL selection (#705).
  final void Function(String report) onMouseReport;

  /// Begin an flterm LOCAL selection at the long-pressed 1-based VIEWPORT cell
  /// (#705): the parent maps it to absolute buffer coords (adding the scroll
  /// offset) and SETs `controller.selection` to a collapsed span there. Replaces
  /// the #692 SGR button1-press; the selection PERSISTS after release so Copy
  /// (`selectedText()`) can read it.
  final void Function(int col, int row) onSelectionStart;

  /// Extend the in-progress flterm LOCAL selection's END to the dragged 1-based
  /// VIEWPORT cell (#705): the parent rebuilds `controller.selection` with the
  /// same anchor and the new end, so the highlight GROWS as the finger drags.
  final void Function(int col, int row) onSelectionExtend;

  @override
  State<_PointerGestureRouter> createState() => _PointerGestureRouterState();
}

class _PointerGestureRouterState extends State<_PointerGestureRouter> {
  /// Net horizontal distance (logical px) accumulated across the current
  /// horizontal drag, summed on each `onUpdate` and evaluated once on `onEnd`
  /// (#693). One discrete window step per swipe — we never emit mid-drag.
  double _horizontalDx = 0;

  void _onHorizontalStart(DragStartDetails details) {
    _horizontalDx = 0;
  }

  void _onHorizontalUpdate(DragUpdateDetails details) {
    _horizontalDx += details.delta.dx;
  }

  /// On lift, if the net horizontal travel crossed the threshold, emit ONE
  /// wheel report at the status-line row so tmux's default `WheelUpStatus`/
  /// `WheelDownStatus` binding steps one window (#693).
  void _onHorizontalEnd(DragEndDetails details) {
    final totalDx = _horizontalDx;
    final decision = ghosttyWindowSwitchForSwipe(
      totalDx,
      kGhosttyWindowSwitchThreshold,
    );
    _horizontalDx = 0;
    if (decision == GhosttyWindowSwitch.none) {
      // Still record the swipe so a device repro shows the (sub-threshold) dx.
      _trace('swipe-h', totalDx, 0, null, null, null);
      return;
    }
    final (col, row) = ghosttyStatusRowCell(rows: widget.rows);
    final report = decision == GhosttyWindowSwitch.next
        ? ghosttySgrWheelDown(col: col, row: row) // swipe RIGHT → next-window
        : ghosttySgrWheelUp(col: col, row: row); // swipe LEFT → previous-window
    _trace('swipe-h', totalDx, 0, col, row, report);
    widget.onMouseReport(report);
  }

  void _onScrollUpdate(DragUpdateDetails details) {
    final controller = widget.scrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    final target =
        (position.pixels + ghosttyScrollDeltaForSwipe(details.delta.dy)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if (target == position.pixels) return;
    controller.jumpTo(target);
  }

  /// The overlay's laid-out size — recorded into the gesture log (#699) as the
  /// `size=(w,h)` field so a device repro shows the box the touch mapped over.
  /// The cell map no longer DERIVES the cell size from this (that was the #699
  /// bug); it uses [widget.cellWidth]/[widget.cellHeight] instead.
  Size get _viewportSize {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return Size.zero;
  }

  (int, int) _cellAt(Offset local) {
    return ghosttyCellForPosition(
      dx: local.dx,
      dy: local.dy,
      cellWidth: widget.cellWidth,
      cellHeight: widget.cellHeight,
      cols: widget.cols,
      rows: widget.rows,
    );
  }

  /// Record one gesture event into the #699 gesture log: raw touch pos, the
  /// laid-out overlay size, the live grid, the computed cell, and any SGR bytes
  /// emitted. This is what pins the touch->cell offset on the next device repro.
  void _trace(
    String type,
    double dx,
    double dy,
    int? col,
    int? row,
    String? sgr,
  ) {
    final size = _viewportSize;
    gevent(
      type: type,
      dx: dx,
      dy: dy,
      width: size.width,
      height: size.height,
      cols: widget.cols,
      rows: widget.rows,
      col: col,
      row: row,
      sgr: sgr,
      mouseTracking: widget.mouseTrackingLabel,
      handledBy: 'overlay',
    );
  }

  void _onLongPressStart(LongPressStartDetails details) {
    widget.onFocus(); // focus only — a selection must NOT pop the keyboard.
    final local = details.localPosition;
    final (col, row) = _cellAt(local);
    // #705: drive flterm's LOCAL selection (NOT a tmux SGR drag, which tmux's
    // default copy-and-cancel would clear on release). Anchor a collapsed
    // selection at the pressed cell; the parent adds the scroll offset.
    _trace('longpress-select', local.dx, local.dy, col, row, 'start');
    widget.onSelectionStart(col, row);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final local = details.localPosition;
    final (col, row) = _cellAt(local);
    // #705: extend the LOCAL selection's END to the dragged cell so the
    // highlight grows under the finger.
    _trace('longpress-select', local.dx, local.dy, col, row, 'extend');
    widget.onSelectionExtend(col, row);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    final local = details.localPosition;
    final (col, row) = _cellAt(local);
    // #705: do NOTHING that clears the selection — leave `controller.selection`
    // SET so it PERSISTS for the Copy button. No SGR release is sent.
    _trace('longpress-select', local.dx, local.dy, col, row, 'end');
  }

  /// Handle a discrete TAP (#693). ALWAYS focus + raise the keyboard via
  /// [widget.onTap]. When the overlay is ACTIVE (mouse mode on), ALSO forward an
  /// SGR button1 CLICK (press+release at the tapped cell, no motion) so tmux
  /// selects the clicked status-bar window / pane. In the inactive (plain-shell)
  /// branch this handler isn't used for the click — see [build] — only the
  /// keyboard raise runs.
  void _onTapUp(TapUpDetails details) {
    // Order: focus + raise the keyboard FIRST so the IME comes up regardless of
    // whether the click forwards (the keyboard is the always-on behaviour).
    widget.onTap();
    final local = details.localPosition;
    if (!ghosttyTapShouldForwardClick(active: widget.active)) {
      _trace('tap', local.dx, local.dy, null, null, null);
      return;
    }
    final (col, row) = _cellAt(local);
    final report = ghosttySgrMousePress(col: col, row: row);
    _trace('tap', local.dx, local.dy, col, row, report);
    GhosttySelectionDriver(
      onReport: widget.onMouseReport,
    ).click(col: col, row: row);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      // #693: NOT inert. flterm's own tap calls only `requestFocus()`, which
      // never raises the Android IME, so a plain-shell tap left the keyboard
      // down. A TRANSLUCENT tap layer lets the pointer fall through to flterm
      // (its own focus/scroll/selection still run) while we additionally raise
      // the keyboard on tap. No SGR is emitted here (plain shell, no mouse mode).
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        child: const SizedBox.expand(),
      );
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        VerticalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
              () => VerticalDragGestureRecognizer(
                // Restrict to touch: a real mouse drag should still reach the
                // remote (mouse mode wants mouse drags); only FINGER swipes are
                // re-routed to scroll.
                supportedDevices: const {PointerDeviceKind.touch},
              ),
              (recognizer) => recognizer.onUpdate = _onScrollUpdate,
            ),
        // #693: a horizontal touch swipe switches the tmux window. Touch-only
        // (like the vertical one) so a real mouse drag still reaches the remote.
        // The arena disambiguates by dominant axis: a vertical-ish swipe wins the
        // vertical recogniser (scroll), a horizontal-ish swipe wins this one. We
        // accumulate dx across updates and emit ONE wheel report at the status
        // row on end — tmux's default Wheel{Up,Down}Status steps one window.
        HorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer
            >(
              () => HorizontalDragGestureRecognizer(
                supportedDevices: const {PointerDeviceKind.touch},
              ),
              (recognizer) => recognizer
                ..onStart = _onHorizontalStart
                ..onUpdate = _onHorizontalUpdate
                ..onEnd = _onHorizontalEnd,
            ),
        // #692: a deliberate touch long-press-drag drives a remote selection by
        // synthesising SGR mouse reports. Touch-only so it never competes with a
        // mouse drag. Loses the arena to the vertical drag on a move-first swipe.
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                supportedDevices: const {PointerDeviceKind.touch},
              ),
              (recognizer) => recognizer
                ..onLongPressStart = _onLongPressStart
                ..onLongPressMoveUpdate = _onLongPressMoveUpdate
                ..onLongPressEnd = _onLongPressEnd,
            ),
        // #693: use onTapUp (it carries the position; onTap does not) so the tap
        // maps to a cell and forwards an SGR CLICK to tmux. Still raises the
        // keyboard via _onTapUp -> widget.onTap.
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (recognizer) => recognizer.onTapUp = _onTapUp,
            ),
      },
      child: const SizedBox.expand(),
    );
  }
}

/// A session terminal rendered with flterm (libghostty). Wires the active
/// session's proxy I/O to an flterm [TerminalController], applies the
/// per-session font/size (#686), and exposes copy + select-all affordances that
/// drive flterm's native selection (#582/#684/#686).
class GhosttyTerminalView extends ConsumerStatefulWidget {
  const GhosttyTerminalView({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<GhosttyTerminalView> createState() =>
      _GhosttyTerminalViewState();
}

class _GhosttyTerminalViewState extends ConsumerState<GhosttyTerminalView> {
  TerminalController? _controller;

  /// Scrollback controller shared with the flterm [TerminalView] so the #690
  /// swipe-scroll overlay can drive scrollback (→ flterm wheel reports) instead
  /// of letting flterm forward a swipe as a remote button drag.
  final TerminalScrollController _scrollController = TerminalScrollController();

  /// PTY output (bytes) -> controller.write subscription. Cancelled on dispose.
  StreamSubscription<Uint8List>? _outputSub;

  /// Live remote mouse-tracking mode, mirrored from the controller (#690). The
  /// controller is a `ChangeNotifier` that fires when the remote toggles mouse
  /// mode; we rebuild so the swipe-scroll overlay activates/deactivates.
  MouseTracking _mouseTracking = MouseTracking.none;

  String? _initError;

  /// Live grid dimensions, mirrored from `controller.onResize`, so the #692
  /// gesture router can map a touch pixel -> 1-based terminal cell for the
  /// SGR mouse reports that drive a remote (tmux) selection on long-press-drag.
  int _cols = 0;
  int _rows = 0;

  /// #705: the long-press selection ANCHOR — the 1-based VIEWPORT cell of the
  /// long-press-start, held while the finger drags so each extend rebuilds the
  /// flterm `TerminalSelection` with this fixed start and the moving end. Null
  /// when no selection gesture is in progress.
  int? _selAnchorCol;
  int? _selAnchorRow;

  /// #702: the session proxy, resolved once in [initState] so the shellReady
  /// subscription + forced resize re-sync don't re-walk the sessions list.
  SshSessionProxy? _proxy;

  /// #702: subscription to the proxy's `shellReady` stream — the moment the
  /// task-side shell EXISTS (so a forced re-sync is NOT dropped by session_host's
  /// `s.shell?.resize`). The xterm path's #666 fit-burst is offstage for ghostty
  /// (it hunts xterm's `TerminalViewState`), so without this the ONLY PTY resize
  /// is the pre-shellReady one tmux drops. Re-fires on reconnect (each shell open
  /// emits a tick). Cancelled on dispose.
  StreamSubscription<void>? _shellReadySub;

  /// #702: pending delayed re-sync timers from the post-shellReady burst, tracked
  /// so dispose cancels them and a gone widget is never re-synced.
  final List<Timer> _resyncTimers = <Timer>[];

  /// #704: the lifecycle state seen on the previous `ref.listen` tick, so
  /// [ghosttyShouldRefreshOnLifecycle] can detect a transition INTO `resumed`
  /// (and not double-fire on a `resumed → resumed` repeat). Null until the
  /// first tick. NOTE: `ref.listen` already hands us `prev`, but the
  /// StateProvider can re-emit the same value; gating on the transition keeps
  /// the resume burst single-shot.
  AppLifecycleState? _lastLifecycle;

  @override
  void initState() {
    super.initState();
    final proxy = _resolveProxy();
    if (proxy == null) {
      _initError = 'No session for ${widget.sessionId}';
      return;
    }
    _proxy = proxy;
    try {
      final controller = TerminalController();
      // Keystrokes (controller.onOutput) -> SSH stdin. Gate on a LIVE session,
      // mirroring the xterm path in sessions.dart: a dead PTY drops input
      // rather than landing escape/mouse bytes as literal text on a re-opened
      // shell.
      controller.onOutput = (bytes) {
        if (proxy.data.state != SshSessionState.connected) return;
        proxy.sendInput(bytes);
      };
      // Grid resize -> PTY resize. flterm reports (cols, rows); the proxy's
      // pixel sizes default to 0 (the task isolate only needs cols/rows). Also
      // mirror (cols, rows) so the #692 gesture router can map touch -> cell.
      controller.onResize = (cols, rows) {
        proxy.sendResize(cols, rows);
        _cols = cols;
        _rows = rows;
      };
      // PTY output bytes -> terminal. The subscription lives on this state so
      // dispose() cancels it.
      _outputSub = proxy.output.listen((bytes) {
        try {
          controller.write(bytes);
        } catch (_) {
          // Defensive — a single PTY byte must never crash the session.
        }
      });
      // Track remote mouse-mode changes so the #690 swipe-scroll overlay turns
      // on/off as the remote toggles mouse reporting (e.g. tmux mouse on/off).
      controller.addListener(_syncMouseTracking);
      _mouseTracking = controller.mouseTracking;
      _controller = controller;
      // #702: arm the first-connect resize re-sync on the proxy's shellReady
      // stream. The xterm #666 fit-burst is offstage for ghostty, so this is the
      // ghostty-LOCAL equivalent: once the task-side shell EXISTS, force-re-send
      // the current grid so the size that reaches tmux is the post-layout one,
      // not the pre-shellReady default that gets dropped. Re-fires on reconnect.
      _shellReadySub = proxy.shellReady.listen((_) {
        if (!mounted) return;
        _armResizeResync();
      });
    } catch (e) {
      // If libghostty's native .so failed to load, surface it instead of a
      // blank crash so the device tester can report it (mirrors the spike).
      _initError = 'flterm init failed: $e';
    }
  }

  /// Mirror the controller's live mouse-tracking mode into [_mouseTracking],
  /// rebuilding only when it actually changes (the controller notifies on many
  /// unrelated events too) so the swipe-scroll overlay (#690) follows the remote.
  void _syncMouseTracking() {
    final controller = _controller;
    if (controller == null) return;
    final next = controller.mouseTracking;
    if (next == _mouseTracking) return;
    if (mounted) setState(() => _mouseTracking = next);
  }

  SshSessionProxy? _resolveProxy() {
    for (final e in ref.read(sessionsProvider).entries) {
      if (e.id == widget.sessionId) return e.proxy;
    }
    return null;
  }

  /// #702: on `shellReady`, force a resize re-sync now, then a short burst of
  /// delayed re-syncs ([kGhosttyResyncBurstMs]). flterm may not have laid out its
  /// real grid at the exact shellReady instant (so `_cols`/`_rows` may still be
  /// 0), so the burst keeps re-trying until the grid is valid — at least one tick
  /// lands after flterm settles, mirroring the xterm #659/#666 burst. Re-armed on
  /// every shellReady (reconnect), cancelling any pending burst first so a
  /// reconnect's burst doesn't stack on the previous one.
  void _armResizeResync() {
    for (final t in _resyncTimers) {
      t.cancel();
    }
    _resyncTimers.clear();
    // Immediate: covers the case where flterm already laid out by shellReady
    // (e.g. a reconnect, where the grid is already valid).
    _forceResizeResync('shellReady');
    for (final ms in kGhosttyResyncBurstMs) {
      _resyncTimers.add(
        Timer(Duration(milliseconds: ms), () => _forceResizeResync('+${ms}ms')),
      );
    }
  }

  /// #702: FORCE-re-send the current grid to the PTY (even if unchanged) so tmux
  /// re-sizes to the post-shellReady layout. Guarded by [ghosttyShouldResyncResize]
  /// (connected + valid `_cols`/`_rows`); a tick with no valid grid is a no-op.
  /// Every forced re-sync is recorded in the gesture/connect trace so a device
  /// repro CONFIRMS a real resize landed after shellReady (`ghostty-resync`).
  void _forceResizeResync(String trigger) {
    if (!mounted) return;
    final proxy = _proxy;
    if (proxy == null) return;
    final connected = proxy.data.state == SshSessionState.connected;
    if (!ghosttyShouldResyncResize(
      connected: connected,
      cols: _cols,
      rows: _rows,
    )) {
      gtrace(
        'ghostty-resync $trigger: skip '
        '(connected=$connected cols=$_cols rows=$_rows)',
      );
      return;
    }
    proxy.sendResize(_cols, _rows);
    gtrace('ghostty-resync $trigger: cols=$_cols rows=$_rows');
  }

  /// #704: on app switch-away-and-back, RE-FIT then REFRESH the flterm view.
  ///
  /// `_SessionTerminalBody` renders [GhosttyTerminalView] for the ghostty
  /// backend and skips the xterm-only resume machinery, so on resume flterm
  /// neither re-lays-out nor repaints — it shows stale/blank content (and the
  /// PTY keeps its backgrounded grid) until a tap or scroll forces a frame.
  /// This handler, fired on the lifecycle transition INTO `resumed`
  /// ([ghosttyShouldRefreshOnLifecycle]), does both:
  ///
  ///   1. RE-FIT ("not laid out"): re-arm the SAME #702 forced-resize burst
  ///      ([_armResizeResync]) so flterm re-lays-out its grid and the current
  ///      cols/rows reach the PTY (tmux) again — the mechanism is identical to
  ///      first-connect, just triggered by resume instead of `shellReady`.
  ///   2. REFRESH ("not refreshed"): pull the latest output back into view.
  ///      The live `proxy.output → controller.write` stream remains the source
  ///      of truth (a connected session's bytes keep flowing); the global
  ///      resume-rebind (#551/connection_providers.dart) also re-requests a
  ///      task-side snapshot. What's missing is a FRAME: flterm only repaints
  ///      when its controller/scroll notifies. So we nudge it — `scrollToBottom`
  ///      (jump to the latest content, which fires the scroll listener → a
  ///      frame, mirroring the xterm/PWA "resume shows latest" semantics) plus a
  ///      post-frame `setState` to rebuild the subtree and guarantee a repaint
  ///      even if the buffer was unchanged.
  ///
  /// Guarded: only when the session is connected (a dead PTY has nothing to
  /// re-fit/refresh), and single-shot per resume via the transition gate.
  void _onResume() {
    if (!mounted) return;
    final proxy = _proxy;
    if (proxy == null) return;
    if (proxy.data.state != SshSessionState.connected) {
      gtrace('ghostty-resume: skip (not connected)');
      return;
    }
    // 1. RE-FIT: reuse the #702 forced-resize burst so flterm re-lays-out and
    //    tmux gets the current grid again after the background pause.
    gtrace('ghostty-resume-refit: cols=$_cols rows=$_rows');
    _armResizeResync();
    // 2. REFRESH: nudge flterm to repaint the latest buffer. scrollToBottom
    //    pins the viewport to the newest output (and fires the scroll listener
    //    → a frame); the post-frame setState forces a rebuild so the repaint
    //    lands even when the content is unchanged.
    final controller = _controller;
    if (controller != null) {
      controller.scrollToBottom();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
    });
    gtrace('ghostty-resume-refresh: cols=$_cols rows=$_rows');
  }

  /// #705: begin an flterm LOCAL selection at the long-pressed 1-based VIEWPORT
  /// cell. Anchor it (held for the drag) and SET `controller.selection` to a
  /// collapsed span at that cell — mapped to absolute buffer rows by adding the
  /// live scrollback offset, mirroring flterm's own `selectWord`/`selectLine`
  /// (`.scroll(scrollbar.offset)`). Unlike the #692 SGR-tmux path, this PERSISTS
  /// after release so Copy (`selectedText()`) can read it.
  void _onSelectionStart(int col, int row) {
    final controller = _controller;
    if (controller == null) return;
    _selAnchorCol = col;
    _selAnchorRow = row;
    controller.selection = ghosttySelectionForCells(
      startViewCol: col,
      startViewRow: row,
      endViewCol: col,
      endViewRow: row,
      scrollOffset: controller.scrollbar.offset,
    );
  }

  /// #705: extend the in-progress LOCAL selection's END to the dragged 1-based
  /// VIEWPORT cell, keeping the held anchor as the start, so the highlight grows
  /// under the finger. No-op if no anchor is set (no selection in progress).
  void _onSelectionExtend(int col, int row) {
    final controller = _controller;
    if (controller == null) return;
    final anchorCol = _selAnchorCol;
    final anchorRow = _selAnchorRow;
    if (anchorCol == null || anchorRow == null) return;
    controller.selection = ghosttySelectionForCells(
      startViewCol: anchorCol,
      startViewRow: anchorRow,
      endViewCol: col,
      endViewRow: row,
      scrollOffset: controller.scrollbar.offset,
    );
  }

  Future<void> _copySelection() async {
    final controller = _controller;
    if (controller == null) return;
    final text = controller.selectedText();
    if (text.isEmpty) {
      if (mounted) {
        showTopToast(
          context,
          'No selection — long-press the terminal, then drag (or tap Select all).',
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTopToast(context, 'Copied ${text.length} chars');
  }

  /// Select the whole buffer (incl. scrollback) via flterm's native select-all
  /// (#686, fix 3 — best-available selection control: flterm 0.0.3 has no
  /// draggable endpoint handles, so a one-tap "select everything then copy"
  /// path is the most useful extra control we can offer over long-press-drag).
  void _selectAll() {
    final controller = _controller;
    if (controller == null) return;
    controller.selectAll();
    if (mounted) showTopToast(context, 'Selected all — tap copy to grab it.');
  }

  @override
  void dispose() {
    _shellReadySub?.cancel();
    for (final t in _resyncTimers) {
      t.cancel();
    }
    _resyncTimers.clear();
    _outputSub?.cancel();
    _controller?.removeListener(_syncMouseTracking);
    _controller?.onOutput = null;
    _controller?.onResize = null;
    _controller?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // #704: re-fit + refresh on app switch-away-and-back. The flterm view skips
    // the xterm path's resume machinery, so without this a resume leaves the
    // terminal stale/blank (and the PTY on its backgrounded grid) until a tap
    // or scroll forces a frame. We listen for a transition INTO `resumed` and
    // re-arm the #702 resize burst (re-fit) + nudge a repaint (refresh). Gated
    // by [ghosttyShouldRefreshOnLifecycle] against [_lastLifecycle] so a
    // `resumed → resumed` re-emit doesn't double-fire the burst.
    ref.listen<AppLifecycleState>(lifecycleProvider, (prev, next) {
      final effectivePrev = prev ?? _lastLifecycle;
      _lastLifecycle = next;
      if (ghosttyShouldRefreshOnLifecycle(effectivePrev, next)) {
        _onResume();
      }
    });
    final controller = _controller;
    if (controller == null) {
      return Container(
        key: const Key('ghostty-terminal-error'),
        color: Colors.red.shade900,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          _initError ?? 'flterm unavailable',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      );
    }
    // #686 fix 1: per-session font + size, read from the SAME #679/#640
    // providers the xterm body reads (terminal_screen.dart). Defaults flow from
    // the providers (JetBrainsMono at the default size) for an un-customized
    // session.
    final fontFamily = ref.watch(sessionFontFamilyProvider(widget.sessionId));
    final fontSize = ref.watch(sessionFontSizeProvider(widget.sessionId));
    // #699: measure the REAL flterm cell size from the SAME font + DPR flterm
    // renders with, so the gesture router's touch->cell map divides by the cell
    // height flterm actually laid out (not overlayHeight/rows — the #699 bug).
    final theme = buildGhosttyTheme(family: fontFamily, fontSize: fontSize);
    final devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final cellSize = ghosttyMeasureCellSize(
      fontSize: theme.fontSize,
      fontFamily: theme.fontFamily,
      fontWeight: theme.fontWeight,
      fontFamilyFallback: theme.fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
    );
    return Stack(
      key: Key('ghostty-terminal-${widget.sessionId}'),
      children: [
        Positioned.fill(
          child: TerminalView(
            controller: controller,
            autofocus: false,
            theme: theme,
            // #699: kGhosttyTerminalPadding mirrors this literal — the
            // touch->cell map subtracts it. Keep them in sync.
            padding: const EdgeInsets.all(kGhosttyTerminalPadding),
            // #690: share the scroll controller so the overlay below can drive
            // scrollback (→ flterm wheel reports) under remote mouse mode.
            scrollController: _scrollController,
            // #688/#692: swipe = scroll, deliberate long-press-drag = selection.
            // flterm's own touch drag/long-press select are dropped here; the
            // overlay below routes the gesture (long-press-drag drives a remote
            // selection via synthesised SGR reports). See the settings doc for
            // the flterm root cause (touch long-press, not `drag`, was the
            // swipe-select culprit).
            gestureSettings: kGhosttyScrollSettings,
          ),
        ),
        // #690/#692/#693: routes touch so the remote (tmux) behaves. When mouse
        // mode is ON the overlay is OPAQUE and routes the gesture: a finger SWIPE
        // scrolls the scrollback (flterm emits canonical wheel reports — never a
        // remote drag); a deliberate LONG-PRESS-drag drives a remote selection
        // (touch -> cell -> SGR-1006 press/motion/release); a TAP forwards an SGR
        // CLICK so tmux selects the clicked window/pane (#693). When mouse mode is
        // OFF the overlay is a TRANSLUCENT tap layer (#693): the pointer falls
        // through to flterm (its own scroll/select run) but a tap also raises the
        // soft keyboard, which flterm's own tap (requestFocus only) does not. In
        // BOTH branches a tap focuses + raises the keyboard. Sits below the
        // affordance buttons so they stay tappable.
        Positioned.fill(
          child: _PointerGestureRouter(
            active: ghosttySwipeShouldScrollLocally(
              mouseTracking: _mouseTracking,
            ),
            scrollController: _scrollController,
            cols: _cols,
            rows: _rows,
            // #699: hand the REAL cell size down so the router maps a touch to
            // the cell flterm actually rendered (root-cause fix for the offset).
            cellWidth: cellSize.width,
            cellHeight: cellSize.height,
            mouseTrackingLabel: _mouseTracking.name,
            // #693: a tap must FOCUS *and* raise the soft keyboard. flterm's own
            // tap calls only `requestFocus()` (terminal_gesture_detector.dart),
            // which doesn't show the Android IME.
            //
            // Ordering matters (the keyboard-never-opens bug): flterm's
            // `showKeyboard()` only calls `TextInput.show()` when the terminal
            // ALREADY has focus AND its input connection is attached
            // (terminal_controller_impl `_updateKeyboardState`: the
            // `.showing when hasFocus` arm shows; the bare `.showing` arm only
            // re-requests focus). `requestFocus()` is async, so calling
            // `showKeyboard()` synchronously on the next line runs BEFORE focus
            // lands — flterm sets state=showing but never shows, and on the
            // subsequent focus-gain `_onFocusChanged` calls `show()` on a
            // STILL-UNATTACHED connection. Net: no keyboard.
            //
            // Fix: request focus now, then re-show on a microtask (after the
            // focus-apply microtask, so `_onFocusChanged` has attached the
            // connection and `hasFocus` is true).
            //
            // But `showKeyboard()` alone only works ONCE: flterm caches
            // `_keyboardState` and `_updateKeyboardState` early-returns when the
            // new state == current. The IME can be dismissed (system back /
            // swipe-down) WITHOUT a focus change, leaving the state stuck at
            // `.showing` while the keyboard is actually DOWN — so the next tap's
            // `showKeyboard()` is a no-op and the keyboard never returns ("works
            // once, then need the compose view"). So hideKeyboard() FIRST: it
            // forces `.hidden` (resetting the stuck state) and, via its
            // `.hidden when hasFocus` arm, RE-ATTACHES the input connection
            // (covering a dismiss that closed it); then showKeyboard() reliably
            // re-shows. When the IME is already down (the common re-tap case)
            // the hide() is a no-op, so there's no visible blink.
            onTap: () {
              controller.requestFocus();
              Future.microtask(() {
                if (!mounted) return;
                controller.hideKeyboard();
                controller.showKeyboard();
              });
            },
            // Long-press-start focuses without raising the keyboard (selection).
            onFocus: controller.requestFocus,
            onMouseReport: (report) {
              final proxy = _resolveProxy();
              if (proxy == null) return;
              if (proxy.data.state != SshSessionState.connected) return;
              proxy.sendInput(Uint8List.fromList(report.codeUnits));
            },
            // #705: long-press-drag drives flterm's LOCAL selection (persists
            // after release → Copy reads it), not a tmux SGR drag.
            onSelectionStart: _onSelectionStart,
            onSelectionExtend: _onSelectionExtend,
          ),
        ),
        // Selection affordances (bottom-right). A deliberate long-press-drag
        // drives a remote (tmux) native selection via SGR reports (#692);
        // Select-all + Copy operate on flterm's LOCAL selection (Select-all,
        // double/triple-tap) — copying a tmux-native span is tmux's own copy
        // mode. A future smart-select button would select a word/path/URL unit
        // at the tap (PWA selection.ts _selectableUnitAt) — see file header.
        Positioned(
          right: 4,
          bottom: 4,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // #692: select-all (flterm-local). The #688 select-mode toggle is
              // gone — a deliberate long-press-drag now selects automatically.
              Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('ghostty-select-all'),
                  tooltip: 'Select all',
                  iconSize: 18,
                  icon: const Icon(Icons.select_all, color: Colors.white),
                  onPressed: _selectAll,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('ghostty-copy-selection'),
                  tooltip: 'Copy selection',
                  iconSize: 18,
                  icon: const Icon(Icons.copy, color: Colors.white),
                  onPressed: _copySelection,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
