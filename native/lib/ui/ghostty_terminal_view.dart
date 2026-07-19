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
// [GhosttyPointerGestureRouter] / [ghosttySwipeShouldScrollLocally]. The wheel
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
// #708 fix (swipe AXIS-LOCK): the active overlay used two INDEPENDENT drag
// recognisers — a `VerticalDragGestureRecognizer` (→ scroll, #690) and a
// `HorizontalDragGestureRecognizer` (→ window-switch, #702) — competing in the
// gesture arena. The arena commits to whichever crosses ITS slop first, blind to
// the OTHER axis, so a deliberate left/right swipe with slight vertical jitter
// leaked a scroll, and a vertical scroll with horizontal drift tripped a
// window-switch. The fix replaces both with a SINGLE touch `PanGestureRecognizer`
// that sees both components: once total travel passes a slop AND one axis clearly
// dominates (a ratio), it LOCKS to that axis (see [ghosttyAxisLock] /
// [GhosttySwipeAxis]) and ignores the off-axis for the rest of the gesture —
// horizontal runs ONLY the #702 window-switch, vertical runs ONLY the #690
// scroll. The pan loses the arena to LongPress when the finger holds first
// (selection still wins) and never starts on a tap. The window-switch direction
// (left=prev/right=next), one-step-per-swipe + status-row report, the local
// scroll, long-press selection (#705/#706), tap-keyboard/click (#693), resume
// (#704), and cell metrics (#699) are all unchanged.
//
// #719 fix (horizontal swipe MISSED the tmux window-switch after a keyboard
// toggle / resize): the window-switch wheel was emitted at the LIVE local grid's
// status row (`ghosttyStatusRowCell(rows: _rows)`). Device telemetry showed the
// last resize SENT to tmux was rows=28 (a #702 resync) but the local grid had
// since grown to 47 (keyboard toggled), so the wheel fired at row 47 while tmux
// still believed it had 28 rows → the wheel landed BELOW tmux's status line
// (row 28) → `WheelDownStatus`/`WheelUpStatus` never fired → no window switch.
// Two-part fix: (1) every `proxy.sendResize` now routes through a single
// `_sendResize` helper that also records the last-sent grid
// (`_lastSentCols`/`_lastSentRows`), so onResize AND the #702 resync keep tmux's
// rows == what we track; (2) the window-switch wheel targets
// `ghosttyStatusRowCell(rows: lastSentRows)` — tmux's REAL status row — not the
// possibly-diverged live `_rows`, so even mid-resize the wheel lands on tmux's
// current status line. A widget smoke test (`GhosttyPointerGestureRouter`, now
// public) drives a real drag→report assertion in the gate so this can't regress.
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
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// The PER-SESSION theme palettes (#552/#571) are xterm.dart `TerminalTheme`s
// (see [terminalPalettes] / [NamedTerminalTheme] in ui_prefs_providers.dart).
// Both xterm AND flterm export a type named `TerminalTheme`, so the xterm one
// is imported with a prefix to avoid colliding with flterm's (the type this
// view feeds the flterm `TerminalView`). [buildGhosttyTheme] maps from one to
// the other (#716).
import 'package:xterm/xterm.dart' as xterm;

import '../diagnostics/connect_trace.dart' show clifecycle, ctrace;
import '../diagnostics/detection_geom.dart';
import '../diagnostics/feedback_bundle.dart' show scrubSecrets;
import '../diagnostics/gesture_trace.dart';
import '../diagnostics/paint_stats.dart';
import '../diagnostics/session_byte_recorder.dart';
import '../services/clipboard.dart';
import '../services/path_verifier.dart';
import '../services/session_cwd_tracker.dart';
import '../services/session_messages.dart'
    show SftpStatResultEvent, SshTaskEvent, TmuxWindowGesture;
import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../terminal/tmux_control_mode_flag.dart';
import '../state/ctrl_modifier_provider.dart';
import '../state/custom_patterns_providers.dart';
import '../state/detection_exceptions_providers.dart';
import '../state/detection_providers.dart';
import '../state/detection_style_providers.dart';
import '../state/input_mode_reset_provider.dart';
import '../storage/custom_patterns_store.dart';
import '../storage/detection_styles_store.dart' show DetectionStyles;
import '../state/lifecycle_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import '../util/file_url.dart';
import 'detection_style_resolver.dart';
import 'file_browser_screen.dart';
import 'ghostty_gutter_layer.dart';
import 'ghostty_terminal_decorators.dart';
import 'gutter_line_select_layer.dart';
import 'keybar.dart';
import 'path_action_overlay.dart';
import 'top_toast.dart';
import 'url_action_overlay.dart';

/// #962 (Pixel-9 clipboard isolation): while we fix cross-app clipboard
/// propagation, the RIGHT-EDGE GUTTER drag is the SOLE copy path. Body text
/// selection — long-press-drag + the bottom-right Copy/Select-all buttons — is
/// disabled so it can't fire a SECOND, competing clipboard write that clobbers
/// the gutter's clip (the "preview chip empty first" symptom the owner saw on a
/// stock Pixel 9). Flip back to true to restore body selection once the
/// clipboard write is verified end-to-end.
const bool kBodyTextSelectionEnabled = false;

/// #906 Stage 2 gate: whether a control-mode vertical swipe drives the tmux
/// `-CC` scrollback (capture-pane history) instead of the local flterm scroll.
/// OFF until flterm can RENDER a captured history window — the capture
/// request→response byte path is proven, but flterm's own scrollback +
/// follow-to-bottom currently bury the captured rows under the live tail, so
/// wiring the swipe would FREEZE the screen (worse than the local no-op). Flip
/// to true once the flterm scrollback-view render lands.
const bool kControlModeScrollRenders = false;

/// Apply the shared armed keybar Ctrl modifier (#728) to a SOFT-KEYBOARD
/// keystroke flowing through flterm's `controller.onOutput`.
///
/// #694's keybar Ctrl modifier only transformed KEYBAR key presses. There are no
/// letter keys on the keybar, so to send Ctrl+R the user types R on the soft
/// keyboard — input that flows through `controller.onOutput(bytes) →
/// proxy.sendInput` and never reached the keybar's `CtrlModifier`. This is the
/// PURE decision the terminal input path makes once it has read the shared
/// [ctrlModifierProvider] armed flag: given [armed] and the typed [bytes], it
/// returns the bytes to actually send plus whether the one-shot Ctrl should now
/// be cleared.
///
/// Rules (mirroring the keybar's [ctrlTransform] for parity):
///   - NOT [armed]            → passthrough, `shouldClear == false` (nothing to clear);
///   - armed + single ASCII letter (a–z/A–Z) → `& 0x1f` control byte, cleared;
///   - armed + single non-letter (digit, symbol, CR, …) → [ctrlTransform]
///     (which passes non-letters through unchanged), still cleared (one-shot);
///   - armed + multi-byte (len > 1: IME / paste / a CSI escape) → passthrough
///     UNCHANGED so multi-char input is never corrupted, still cleared so the
///     sticky Ctrl can't get stuck.
///
/// Pure (no FFI / no widget / no provider) → unit-testable headless.
({String bytes, bool shouldClear}) ghosttyApplyArmedCtrl({
  required bool armed,
  required String bytes,
}) {
  if (!armed) return (bytes: bytes, shouldClear: false);
  // Multi-byte IME / paste / escape sequences pass through untouched — only a
  // single typed character carries a Ctrl meaning. The one-shot still clears.
  if (bytes.length != 1) return (bytes: bytes, shouldClear: true);
  // Single char: the keybar's transform maps a letter → its control byte and
  // leaves a non-letter unchanged, so keybar-key and keyboard-key Ctrl match.
  return (bytes: ctrlTransform(bytes), shouldClear: true);
}

/// Build the flterm [ColorPalette] for the per-session theme [palette] (#716).
///
/// The per-session theme palettes ([terminalPalettes]) are xterm.dart
/// `TerminalTheme`s carrying background/foreground/cursor/selection + the 16
/// named ANSI colors (black..brightWhite). flterm instead bundles
/// background/foreground + the 16 ANSI colors (as an ordered list) into a
/// [ColorPalette] (cursor + selection live on the THEME, mapped separately by
/// [buildGhosttyTheme]). This maps the xterm palette's ANSI fields → flterm's
/// canonical 0-15 ANSI order so the Ghostty terminal renders in the selected
/// theme's colors, not the hardcoded Tomorrow-Night dark default (#716 root
/// cause). Pure (no FFI / no widget) → unit-testable headless.
ColorPalette ghosttyPaletteFromXterm(xterm.TerminalTheme palette) {
  return ColorPalette(
    background: palette.background,
    foreground: palette.foreground,
    // Canonical ANSI order 0-15: black, red, green, yellow, blue, magenta,
    // cyan, white, then the 8 bright variants. Matches flterm's _darkAnsiColors
    // ordering and tmux/xterm's 16-color index space.
    ansiColors: <Color>[
      palette.black,
      palette.red,
      palette.green,
      palette.yellow,
      palette.blue,
      palette.magenta,
      palette.cyan,
      palette.white,
      palette.brightBlack,
      palette.brightRed,
      palette.brightGreen,
      palette.brightYellow,
      palette.brightBlue,
      palette.brightMagenta,
      palette.brightCyan,
      palette.brightWhite,
    ],
  );
}

/// The per-session [TerminalTheme] for the ghostty backend (#686 fix 1, #716).
///
/// flterm carries font face + size on the THEME (`fontFamily`/`fontSize`), not a
/// separate `textStyle` like xterm.dart — changing either recalculates the
/// flterm cell metrics. Likewise it carries COLORS on the theme (its
/// [ColorPalette] + cursor/selection), where xterm.dart takes a separate `theme`
/// on the `TerminalView`.
///
/// #686 fix 1 mapped only the FONT (face + size). #716 fixes the colors: when a
/// per-session theme [palette] (an xterm.dart `TerminalTheme` from
/// [terminalPalettes]) is supplied, its background/foreground + 16 ANSI colors,
/// cursor, and selection are mapped onto the flterm theme so cycling the theme
/// actually recolors the terminal (previously only the LABEL changed — the
/// builder always started from [TerminalTheme.dark], ignoring the palette). When
/// [palette] is null the builder keeps Ghostty's Tomorrow-Night dark default
/// (preserving the #686 behaviour for callers/tests that pass only font + size).
/// The font face + size always override on top, from the live #679/#640
/// per-session providers.
///
/// [family] is a pubspec-registered family id (e.g. `JetBrainsMono`) — the SAME
/// string the xterm path feeds `TerminalStyle.fontFamily`, and the same id
/// pubspec.yaml registers the bundled TTFs under, so flterm's
/// `FontDataResolver` finds the asset. Pure (no native libghostty .so), so it is
/// unit-testable headless.
///
/// #1074: the theme is built TRANSPARENT (`backgroundOpacity: 0`,
/// `backgroundOpacityCells: false`). The ghostty backend now composites over an
/// app-owned solid backdrop + [GhosttyWashLayer] mounted BELOW the terminal, so
/// the terminal must not paint its own opaque grid fill — at opacity 0 flterm's
/// `background_painter` skips the default-bg grid fill (the backdrop + wash show
/// through) while explicit-bg cells + glyphs stay OPAQUE (cells=false), so they
/// occlude the wash and the text stays full-contrast on top.
TerminalTheme buildGhosttyTheme({
  required String family,
  required double fontSize,
  xterm.TerminalTheme? palette,
}) {
  final base = TerminalTheme.dark();
  if (palette == null) {
    return base.copyWith(
      fontFamily: family,
      fontSize: fontSize,
      backgroundOpacity: 0.0,
      backgroundOpacityCells: false,
    );
  }
  return base.copyWith(
    fontFamily: family,
    fontSize: fontSize,
    // #1074: transparent terminal — the app paints the backdrop + wash below.
    backgroundOpacity: 0.0,
    backgroundOpacityCells: false,
    palette: ghosttyPaletteFromXterm(palette),
    // Cursor + selection live on the THEME (not the ColorPalette). Map the
    // xterm palette's cursor/selection to flterm's fixed DynamicColor so the
    // caret + highlight match the selected theme too. CursorTheme has no
    // copyWith, so rebuild it, preserving the base shape/blink/opacity/text.
    cursor: CursorTheme(
      shape: base.cursor.shape,
      color: DynamicColor.fixed(palette.cursor),
      text: base.cursor.text,
      blinkInterval: base.cursor.blinkInterval,
      opacity: base.cursor.opacity,
    ),
    selection: SelectionTheme(
      background: DynamicColor.fixed(palette.selection),
    ),
  );
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
/// our own [GhosttyPointerGestureRouter] overlay handles touch long-press selection by
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

/// #970: after the resync burst has settled the grid, send a one-shot PTY-size
/// NUDGE (rows-1 → rows) at this delay. Windows ConPTY (and some picky remotes)
/// only emit their prompt/output on a size CHANGE, not a same-size resync — so a
/// fresh connect stays BLANK until the user manually resizes. The nudge forces
/// that window-change. Fires after the 350ms burst tick so the grid is valid.
const int kGhosttyConPtyNudgeMs = 480;

/// #970: the ConPTY-nudge size sequence for a settled grid [cols]x[rows] — a
/// DIFFERENT size (rows-1) to force the remote window-change ConPTY needs, then
/// the real size restored a beat later. Null when the grid is invalid / too
/// small to nudge (`cols <= 0 || rows <= 1`). Pure so the nudge contract is
/// testable without rendering flterm (the native .so can't render headless).
List<({int cols, int rows})>? ghosttyConPtyNudgeSizes(int cols, int rows) {
  if (cols <= 0 || rows <= 1) return null;
  return [(cols: cols, rows: rows - 1), (cols: cols, rows: rows)];
}

/// #903 — the settle window that coalesces a keyboard-animation / layout-reflow
/// burst of `controller.onResize` events into a SINGLE PTY resize at the FINAL
/// stable size.
///
/// Root cause (tmux-state-trace, SINGLE client): flterm fires `onResize` for
/// EVERY layout change, and the ghostty path sent each straight to the PTY. A
/// soft-keyboard show/hide animates the viewport inset over many frames — flterm
/// recomputes its grid each frame, so one keyboard toggle logged a cascade
/// (`44→43→42→38→37→35→34` in a second). The proxy's #848 no-op guard only drops
/// IDENTICAL dims; each animation frame is a DISTINCT height, so every one
/// reached tmux → regrid → repaint race. A window switch shows the same shape as
/// a transient `34→36→34` reflow blip.
///
/// 120ms (the xterm #848 `kMetricsSettleDelay`) is too SHORT — the keyboard
/// animation spans longer, so intermediate frames still slip past it. This window
/// must OUTLAST the soft-keyboard show/hide animation (~100–300ms on Android) so
/// the resize fires once the inset stops moving, off the FINAL chrome-correct
/// viewport. Long enough to span the animation; short enough that a real
/// rotation/resize re-syncs promptly.
const Duration kGhosttyResizeSettle = Duration(milliseconds: 250);

/// #903 — coalesces a burst of grid sizes into ONE settled PTY resize.
///
/// Pure (no FFI / no widget / no provider) → unit-testable headless. flterm
/// can't render headless, so the storm fix lives in this testable seam rather
/// than inside the widget's `onResize` closure.
///
/// Wire-up: `controller.onResize` calls [submit] with each live grid; once the
/// size has been STABLE for [settle] the coalescer calls [onSettled] ONCE with the
/// final dims. Intermediate animation-frame sizes never reach [onSettled]. A
/// transient excursion that returns to the start (the window-switch `34→36→34`
/// blip) coalesces to the original size — and because that equals what was last
/// submitted-as-settled, [skipIfUnchanged] drops it so no spurious resize fires.
///
/// The #666/#702 forced resync must NOT be debounced (it re-pushes the CURRENT
/// size the instant the shell exists). It calls [flushNow] to send immediately,
/// cancelling any pending debounce.
class GhosttyResizeCoalescer {
  GhosttyResizeCoalescer({
    required this.onSettled,
    this.settle = kGhosttyResizeSettle,
    Timer Function(Duration, void Function())? scheduleTimer,
  }) :
       // Injectable for headless tests (a fake scheduler fires synchronously);
       // production uses a real `Timer`.
       _scheduleTimer = scheduleTimer ?? Timer.new;

  /// Called with the FINAL settled (cols, rows) once the size stops changing
  /// for [settle]. In the widget this is `_sendResize` (which records the #719
  /// last-sent grid + writes the PTY).
  final void Function(int cols, int rows) onSettled;

  /// The settle window the resize must stay stable for before [onSettled] fires.
  final Duration settle;

  final Timer Function(Duration, void Function()) _scheduleTimer;

  Timer? _timer;
  int? _pendingCols;
  int? _pendingRows;

  /// The dims the coalescer last EMITTED via [onSettled] (so an excursion that
  /// returns to the last settled size emits nothing). Null until the first emit.
  int? _lastEmittedCols;
  int? _lastEmittedRows;

  /// Test/telemetry: how many times [onSettled] was actually invoked. A keyboard
  /// toggle's N animation frames must increment this by AT MOST one.
  int sendCount = 0;

  /// The last dims submitted (the live grid the gesture map mirrors), regardless
  /// of whether they've settled yet. Null until the first [submit].
  int? get pendingCols => _pendingCols;
  int? get pendingRows => _pendingRows;

  /// #922 (test/telemetry): the last dims actually EMITTED to the PTY (== the
  /// #719 `_lastSentRows` the status-tap targets). Lets the on-emulator keyboard
  /// sizing test assert the SENT grid tracks the keyboard-reduced viewport. Null
  /// until the first emit.
  int? get lastEmittedCols => _lastEmittedCols;
  int? get lastEmittedRows => _lastEmittedRows;

  /// Record a new live grid. Resets the settle timer; the resize is sent only
  /// once the size stops changing for [settle].
  void submit(int cols, int rows) {
    _pendingCols = cols;
    _pendingRows = rows;
    _timer?.cancel();
    _timer = _scheduleTimer(settle, _fire);
  }

  void _fire() {
    _timer = null;
    final cols = _pendingCols;
    final rows = _pendingRows;
    if (cols == null || rows == null) return;
    // The settled size equals the last one we emitted (e.g. a `34→36→34`
    // excursion that returned to 34) → nothing changed, emit nothing. This
    // mirrors the proxy's #848 no-op guard but at the coalescing seam, so the
    // transient never even reaches the gateway.
    if (cols == _lastEmittedCols && rows == _lastEmittedRows) return;
    _lastEmittedCols = cols;
    _lastEmittedRows = rows;
    sendCount += 1;
    onSettled(cols, rows);
  }

  /// Send the CURRENT size to the PTY immediately, bypassing the debounce.
  /// Used by the #666/#702 forced resync (re-pushes the same dims the instant
  /// the shell exists). Cancels any pending debounce and resets the
  /// last-emitted gate so the forced send always lands. Falls back to the
  /// supplied [cols]/[rows] when nothing has been submitted yet.
  void flushNow(int cols, int rows) {
    _timer?.cancel();
    _timer = null;
    _pendingCols = cols;
    _pendingRows = rows;
    // A FORCED resync deliberately re-sends even an unchanged size (the #666
    // re-push of the same dims once the shell exists), so it always lands —
    // the dedup gate is set to the just-sent size for the NEXT debounce. The
    // proxy still owns the #666 one-shot force-bypass of ITS no-op guard.
    _lastEmittedCols = cols;
    _lastEmittedRows = rows;
    sendCount += 1;
    onSettled(cols, rows);
  }

  /// Cancel any pending debounce (dispose / teardown). Does NOT emit.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

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

/// #1085: whether the window went through a real WINDOWING transition between
/// two builds — desktop-mode entry, rotation, or a freeform resize — as opposed
/// to no change or first layout. A soft keyboard changes `viewInsets`, NOT
/// `MediaQuery.size`, so ANY size delta here is a genuine window change. Returns
/// false when [prev] is null (first layout, nothing to transition from) and when
/// the change is sub-pixel jitter (< [epsilon] on both axes). On the true
/// boundary we arm the auto-reply settle so the terminal's re-probed DA/DSR/
/// mouse replies don't leak as `?62c` at the prompt (the #1072 family — un-gated
/// on config-changes because no shellReady fires there).
bool ghosttyWindowChangedMaterially(Size? prev, Size next,
    {double epsilon = 1.0}) {
  if (prev == null) return false;
  return (prev.width - next.width).abs() >= epsilon ||
      (prev.height - next.height).abs() >= epsilon;
}

/// Whether the terminal should be FOCUSED on first connect (#717).
///
/// On the ghostty backend flterm's [TerminalView] is built `autofocus: false`,
/// so on first connect the terminal isn't focused and flterm's
/// scroll/interaction is INERT until the user taps to raise the keyboard (which
/// is what finally focuses it). The owner wants vertical scroll to work
/// immediately on connect WITHOUT having to tap up the keyboard first. The fix
/// is to `controller.requestFocus()` once per connect — focus ONLY, NOT
/// `showKeyboard()` (#693/#706 deliberately separated focus from raising the
/// IME, so the keyboard must NOT auto-pop on connect; a later tap still raises
/// it).
///
/// Guards (all must hold):
///   - [active]: this is the ACTIVE session's view. `_SessionTerminalBody`
///     renders every session in an `IndexedStack` (terminal_screen.dart), so a
///     BACKGROUND session's view is mounted but OFFSTAGE. Focusing it would
///     steal focus from the visible session — so only the active view focuses.
///   - [connected]: the session is live (a dead PTY has nothing to interact
///     with).
///   - NOT [alreadyFocused]: fire ONCE per connect, not on every rebuild — we
///     must not keep stealing focus (e.g. from the compose bar) on each frame.
///
/// Pure (no FFI / no widget) → unit-testable headless.
bool ghosttyShouldFocusOnConnect({
  required bool active,
  required bool connected,
  required bool alreadyFocused,
}) {
  return active && connected && !alreadyFocused;
}

/// Whether a resume must force a flterm repaint via a FOCUS CYCLE rather than a
/// plain `requestFocus()` (#720).
///
/// #718 re-focuses the terminal on resume to drive a repaint, reusing the #717
/// connect-focus path (`controller.requestFocus()`). That works when focus was
/// LOST while backgrounded — the focus CHANGE (unfocused → focused) fires
/// flterm's `_onFocusChanged` → `controller.notifyListeners()` → the
/// `RenderTerminal`'s `_onRenderObserverChanged` → `markNeedsPaint()`.
///
/// But on a device UNLOCK (or any resume where the app kept focus and the grid
/// size didn't change), focus was RETAINED through the lock, so `requestFocus()`
/// is a NO-OP: flterm's `FocusNode` is already focused → no focus change → no
/// `_onFocusChanged` → no notify → no repaint. The view stays STALE until a tap
/// (which only repaints because it forwards an SGR click → tmux emits output →
/// repaint). Telemetry on #720 confirmed `_onResume` ran (`ghostty-resume-refit`
/// / `-refresh` / `ghostty-connect-focus resume: focused`) yet the view stayed
/// stale until tap.
///
/// The fix: when focus is RETAINED, do a real focus CYCLE — `controller.unfocus()`
/// then `controller.requestFocus()` on a POST-FRAME callback. Deferring the
/// refocus one frame makes it a genuine focus CHANGE (focused → unfocused →
/// focused), which fires `_onFocusChanged` and forces the repaint. (A same-frame
/// toggle coalesces to no net change.) `_onFocusChanged` only calls
/// `_textInput.show()` when the keyboard state is already `.showing`; on a resume
/// the keyboard is down (`.hidden`), so refocus re-attaches the input connection
/// but does NOT raise the IME — the keyboard stays down.
///
/// Gating: only cycle when [active] + [connected] (same scope as #717/#718) AND
/// the terminal currently [hasFocus]. If focus was LOST, [hasFocus] is false and
/// the plain `requestFocus()` already produces a real focus change → repaint, so
/// no cycle is needed (and cycling would be redundant). Pure (no FFI / no widget)
/// → unit-testable headless.
bool ghosttyShouldCycleFocusForRepaint({
  required bool active,
  required bool connected,
  required bool hasFocus,
}) {
  return active && connected && hasFocus;
}

/// #922 telemetry sink bound to the flterm render box's `onFrameDebug` (wired in
/// [_findTerminalRenderBox] on every lookup). Routes each compact render/sync line
/// into the durable lifecycle ring via `clifecycle('repaint', …)`, so a device
/// capture of a stale tmux window switch shows WHY a switch didn't repaint —
/// screen transitions, zero-rebuild content syncs (`dirty`/`rebuilt=0`/`markedAll`
/// /`damageUnsettled`/`detActive`), and the #918 settle-tick arm/fire. Top-level +
/// pure (no widget/FFI) so the wiring contract is unit-testable without rendering
/// flterm headless (the native .so can't render in a headless test).
String? _lastRepaintLine;
int _repaintRepeat = 0;

/// Collapse CONSECUTIVE identical frame lines before they hit the ring (#968).
/// A frozen screen (the device "not repainting" repros) emits the same
/// `sync … rebuilt=N` every frame — 500+ identical lines flooded the 600-event
/// lifecycle ring and EVICTED the detection-register + freeze-onset lines that
/// actually diagnose it. Emit a line only when it CHANGES, carrying a `×N`
/// repeat count for the run just ended (feedback_suppress_identical_logs).
void logRepaintTelemetry(String line) {
  if (line == _lastRepaintLine) {
    _repaintRepeat++;
    return;
  }
  final prev = _lastRepaintLine;
  final repeat = _repaintRepeat;
  _lastRepaintLine = line;
  _repaintRepeat = 0;
  if (prev != null && repeat > 0) {
    clifecycle('repaint', '$prev ×${repeat + 1}');
  }
  clifecycle('repaint', line);
}

/// #741: whether THIS session's view is the one LEAVING active on a session-bar
/// swipe-switch and so must CAPTURE its current keyboard-up state.
///
/// An app-level session-bar swipe switches the active session
/// (terminal_screen.dart `_SessionBar.onSwipe` → `setActive`). Every session's
/// terminal is mounted in an `IndexedStack`, so the OUTGOING (focused) view goes
/// offstage — its `TextInput` connection detaches and the keyboard collapses —
/// while the INCOMING view is never focused. The bar then jumps down out from
/// under the finger (the keyboard inset vanished). The keyboard state lives in
/// each view's flterm controller, unreachable from the bar, so the outgoing view
/// records whether its keyboard was up (into
/// [sessionSwitchKeyboardWasUpProvider]) for the incoming view to restore.
///
/// True only on a REAL switch AWAY from this session: `prevActiveId` is this
/// session, `nextActiveId` is a DIFFERENT session. A same-id re-emit (no switch)
/// and a first-tick `prevActiveId == null` (initial activation, not a switch) do
/// not capture. Pure (no FFI / no widget) → unit-testable headless.
bool ghosttyShouldCaptureKeyboardOnSessionSwitch({
  required String sessionId,
  required String? prevActiveId,
  required String? nextActiveId,
}) {
  if (prevActiveId == null) return false;
  if (prevActiveId == nextActiveId) return false;
  return prevActiveId == sessionId;
}

/// #741: whether THIS session's view is the one BECOMING active on a session-bar
/// swipe-switch and so must RE-ATTACH focus (and, per
/// [ghosttyShouldShowKeyboardOnSessionSwitch], re-show the keyboard) so the IME
/// never collapses.
///
/// True only on a REAL switch INTO this session: `nextActiveId` is this session,
/// `prevActiveId` is a DIFFERENT non-null session. A same-id re-emit is not a
/// switch; a first-tick `prevActiveId == null` is the initial activation, which
/// the #717 connect-focus path already owns (restoring here would fight the
/// per-connect focus latch and could raise the IME on cold start — the
/// #693/#717 focus-vs-keyboard separation). Pure → unit-testable headless.
bool ghosttyShouldRestoreFocusOnSessionSwitch({
  required String sessionId,
  required String? prevActiveId,
  required String? nextActiveId,
}) {
  if (prevActiveId == null) return false;
  if (prevActiveId == nextActiveId) return false;
  return nextActiveId == sessionId;
}

/// #741: whether the incoming view must RE-SHOW the keyboard after re-attaching
/// focus on a session-bar switch. The contract is "leave the keyboard state
/// UNCHANGED": re-show iff it was up before the switch ([keyboardWasUp], captured
/// by the outgoing view). When it was down, focus only — the keyboard stays
/// down. Pure → unit-testable headless.
bool ghosttyShouldShowKeyboardOnSessionSwitch({required bool keyboardWasUp}) {
  return keyboardWasUp;
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

/// #922: compute the KEYBOARD-AWARE grid (cols, rows) that tmux must be told to
/// use, from the terminal box's laid-out size and the REAL flterm cell size.
///
/// Root cause (#922, device capture 2026-06-25T18-09-02): the PTY resize was
/// driven SOLELY by flterm's `controller.onResize`, which flterm fires from its
/// own layout. Under the soft-keyboard show/hide animation that callback races —
/// the grid transiently shrinks to the keyboard-reduced size, then SETTLES BACK
/// to the pre-keyboard (tall) size. The gesture log proved it: at tap time the
/// box was 597px (keyboard UP, ~34 visible rows) but flterm reported `grid=58x57`
/// AND `sent=58x57`. tmux therefore believed it had 57 rows and drew its status
/// bar at row ~56 — BELOW the keyboard, off-screen. A tap on the visible bottom
/// (row 34) landed in the MIDDLE of tmux's grid: cursor moved, no window switch.
///
/// The fix makes the host compute the authoritative grid ITSELF from the box the
/// Scaffold has ALREADY shrunk for the keyboard (`resizeToAvoidBottomInset:true`
/// in terminal_screen.dart resizes the body, so [boxHeight] from a LayoutBuilder
/// is the keyboard-reduced visible height). We mirror flterm's own grid math:
/// subtract the [TerminalView] padding from both axes, then floor by the REAL
/// cell size. This value is submitted to the resize coalescer so the FINAL
/// settled size tracks the VISIBLE viewport, keeping tmux's status bar at the
/// visible bottom and the #719 status-tap (which targets the last-SENT rows)
/// landing on it.
///
/// Defensive: a zero/degenerate box or cell size yields a 1×1 grid (the same
/// floor used by [ghosttyCellForPosition]) so a pre-layout frame never sends a
/// nonsense resize. Pure (no FFI / no widget) → unit-testable headless.
(int cols, int rows) ghosttyGridForBox({
  required double boxWidth,
  required double boxHeight,
  required double cellWidth,
  required double cellHeight,
  double padding = kGhosttyTerminalPadding,
}) {
  if (cellWidth <= 0 || cellHeight <= 0) return (1, 1);
  final innerW = boxWidth - 2 * padding;
  final innerH = boxHeight - 2 * padding;
  final cols = (innerW / cellWidth).floor();
  final rows = (innerH / cellHeight).floor();
  return (cols < 1 ? 1 : cols, rows < 1 ? 1 : rows);
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

/// Re-anchor a content-frame [TerminalSelection] when the scrollback buffer's
/// oldest lines are EVICTED, so the highlight keeps tracking the SAME text as
/// output streams (#706, issue 1).
///
/// flterm stores a selection in the ABSOLUTE, TOP-ANCHORED buffer frame: row 0
/// is the OLDEST line currently in the buffer, and the painter renders viewport
/// row `r` as selected iff `selection.contains(r + scrollbar.offset)` (see
/// terminal_frame_builder.dart `_RowSelection`), with `selectedText` extracting
/// over the same `PointTag.screen` frame. While the bounded scrollback is still
/// FILLING, every line keeps its absolute index, so a selection built via
/// [ghosttySelectionForCells] (which already `.scroll(offset)`s into this frame)
/// AUTO-tracks streaming content — the painter re-reads the grown `offset` each
/// dirty frame and the highlight slides UP with its text, exactly as wanted.
///
/// The ONE case the absolute frame does NOT self-correct is scrollback
/// EVICTION: once the buffer is capped, each new line drops the oldest line, so
/// every surviving line's absolute index shifts DOWN by the number of evicted
/// lines. We detect that as a DROP in the scrollback length — `prevScrollbackLen`
/// (the `total - visible` captured on the previous tick) exceeding
/// `nextScrollbackLen` would never happen while merely filling; but once capped,
/// `nextScrollbackLen` plateaus while content keeps scrolling, so we instead
/// shift by the supplied [evictedRows] (lines pushed past the cap since the last
/// tick). A positive [evictedRows] shifts the selection UP (negative delta) to
/// stay on its content; rows that scroll entirely off the top (above row 0) are
/// CLAMPED to 0 so the selection degrades to the oldest surviving line rather
/// than pointing at wrong content or going negative.
///
/// Returns the re-anchored selection, or null when the whole span has scrolled
/// off the top (both endpoints evicted) — the caller then clears it. Pure (no
/// FFI / no widget) so the row math is unit-testable headless.
TerminalSelection? ghosttyReanchorForEviction(
  TerminalSelection selection, {
  required int evictedRows,
}) {
  if (evictedRows <= 0) return selection;
  final newStartRow = selection.startRow - evictedRows;
  final newEndRow = selection.endRow - evictedRows;
  // Both endpoints scrolled off the top → the selection is gone.
  if (newStartRow < 0 && newEndRow < 0) return null;
  return TerminalSelection(
    startRow: newStartRow < 0 ? 0 : newStartRow,
    startCol: selection.startCol,
    endRow: newEndRow < 0 ? 0 : newEndRow,
    endCol: selection.endCol,
    mode: selection.mode,
  );
}

/// Whether a single TAP should DISMISS an active selection (and SWALLOW the tap)
/// rather than forward a click / type (#706, issue 2).
///
/// Owner workflow: long-press begin → drag to select → release (the selection
/// PERSISTS, #705) → TAP ANYWHERE ONCE → dismiss → long-press to begin again. So
/// when a selection is active, a tap's PRIMARY job is to clear it; the tap must
/// NOT also forward the #693 SGR click (which would step a tmux window) or do
/// anything else with the gesture. When there is NO active selection, the tap
/// behaves exactly as before (focus + raise keyboard +, under mouse mode, an SGR
/// click). Pure, so the decision is unit-testable headless.
bool ghosttyTapShouldDismissSelection({required bool hasSelection}) =>
    hasSelection;

/// Whether an active selection should be INVALIDATED (cleared) because fresh
/// REMOTE OUTPUT redrew the content under it (#760).
///
/// #760 root cause: a touch selection (#705/#706) is anchored to ABSOLUTE buffer
/// rows. [ghosttyReanchorForEviction] keeps it on its CONTENT while the
/// primary-screen scrollback FILLS or EVICTS (the same text just slides). But
/// the common "scroll" here is a tmux / remote REDRAW: tmux runs on the ALTERNATE
/// screen (no scrollback, `scrollbar.offset` pinned at 0) and replaces the
/// content AT THE SAME viewport rows via the OUTPUT stream — the local offset
/// never changes, so the absolute-row selection stays put over now-DIFFERENT
/// text and highlights stale/irrelevant cells ("highlighted nothing"). The
/// selected text is gone, so the selection is meaningless and must clear.
///
/// The rule that distinguishes a redraw from a pure LOCAL scrollback scroll: a
/// scrollback scroll fires a controller notify with NO `controller.write()` (no
/// new bytes — the same content just moves, which the absolute frame already
/// tracks), whereas a remote redraw arrives as fresh PTY bytes written to the
/// controller. So we clear ONLY when [hasSelection] AND fresh [remoteOutput]
/// caused this notify — never on a pure scroll. This mirrors the #750 URL
/// clear-on-change but for selection. (Conservative-but-correct: on the primary
/// screen, streaming output also clears the short-lived selection — selections
/// are select → Copy → done; a desktop-style persist-through-output isn't
/// expected on a live mobile tmux. Eviction tracking still runs FIRST for the
/// in-flight scrollback-fill case.) Pure → unit-testable headless.
bool ghosttySelectionInvalidatedByOutput({
  required bool hasSelection,
  required bool remoteOutput,
}) => hasSelection && remoteOutput;

/// Whether the bottom-right selection affordance buttons (Copy + Select-all)
/// should be SHOWN (#712).
///
/// The owner wants a CLEAN terminal: the Copy / Select-all buttons appear ONLY
/// while a selection is active (`controller.selection != null`), and disappear
/// when there is none — e.g. before any long-press-drag (#705/#706), and after a
/// single tap dismisses the selection (#706). When [hasSelection] is false the
/// caller renders nothing in that corner. Pure, so the decision is unit-testable
/// headless.
bool ghosttyShouldShowAffordances({required bool hasSelection}) => hasSelection;

/// #828: the text Copy should grab, given the LIVE flterm selection's extracted
/// text and the SNAPSHOT captured when the user finalised the selection.
///
/// #828 root cause: under tmux MOUSE MODE the remote redraws continuously (the
/// status-bar clock ticks ~1/s, the cursor blinks). #760's
/// [_invalidateSelectionOnRedraw] clears the LOCAL `controller.selection` on the
/// FIRST remote output after a selection exists — so ~1s after a deliberate
/// long-press-drag the live selection is already null, while the painted
/// highlight from the last frame LINGERS on screen (the user still SEES a
/// selection). `controller.selectedText()` then returns '' and Copy
/// false-negatives with "No selection" despite a visibly-selected region.
///
/// The reconciliation: snapshot the selected text at finalise time (the exact
/// text the user saw highlighted) and PREFER that snapshot — it is the faithful
/// record of what the user dragged across. The LIVE extraction is only a
/// fallback for when no snapshot was captured (e.g. an flterm-native
/// double/triple-tap selection that doesn't route through our drag handlers).
/// Both empty means there genuinely is nothing to copy (then Copy may toast).
///
/// P0 (#962, build +88): preferring the LIVE extraction copied the WRONG region.
/// In an active streaming session, after the user finalises a SCROLLED-BACK
/// selection, fresh output keeps arriving; the live `selectedText()` re-extracts
/// against a shifted buffer and drifts to the live TAIL (the owner selected one
/// block but the clipboard got later output — "the wrong tmux view"). The
/// drag-time snapshot is immune to that drift, so it is the source of truth.
/// Pure, so the decision is unit-testable headless.
String ghosttyEffectiveCopyText(String live, String snapshot) =>
    snapshot.isNotEmpty ? snapshot : live;

/// #828: whether there is a copyable selection to reflect in the UI, given the
/// LIVE selection presence and the finalised-text [snapshot]. A live selection
/// always counts; a surviving snapshot keeps Copy reachable after a #760 redraw
/// cleared the live one (so the affordance buttons don't vanish and a tap still
/// dismisses it). Mirrors [ghosttyEffectiveCopyText]'s "live OR snapshot" rule
/// for the visibility/dismiss path. Pure → unit-testable headless.
bool ghosttyHasCopyableSelection({
  required bool liveSelection,
  required String snapshot,
}) => liveSelection || snapshot.isNotEmpty;

/// #1014: DECRST sequence resetting every synthesized-input-gating DEC private
/// mode to its default, written LOCALLY into the terminal parser
/// (`controller.write`) at the REVIVE boundary (`proxy.shellReady`, which
/// re-fires on every reconnect — the same seam as the #702 resize-resync and
/// the #717 focus latch).
///
/// Why: the flterm controller (and the libghostty VT terminal under it)
/// SURVIVES a reconnect — only the task-side shell reopens. A pre-drop
/// mouse-reporting TUI (tmux, mouse on) leaves `mouseTracking` ON, so the
/// gesture overlay kept synthesizing SGR reports into the revived remote; a
/// plain shell renders them as literal `[<65;...M` text at the prompt (owner
/// telemetry 2026-07-08T18-13-09: sentSgrTrace bursts right after a SUCCESSFUL
/// 5-session reconnect). Resetting the parser at shellReady re-syncs the local
/// mode state to a fresh shell's reality; if the remote's TUI is still alive
/// (tmux auto-attach) its redraw re-emits DECSET through the byte stream and
/// the parser re-enables the modes naturally — no user action, no heuristics.
///
/// Ordering is safe: shellReady and PTY output arrive on the SAME gateway IPC
/// stream (ssh_session_proxy `_handleEvent`), so this reset always lands
/// BEFORE the revived shell's first output bytes.
///
/// Covered modes (all remote-toggled, all gate synthesized input):
///   9/1000/1002/1003  mouse tracking (drive `controller.mouseTracking`);
///   1005/1006/1015    mouse report encodings (UTF-8 / SGR / urxvt);
///   1007              alternate scroll (wheel → arrow keys on alt screen);
///   2004              bracketed paste.
/// Deliberately NOT reset: the alternate SCREEN (would blank the restored
/// grid) and DECCKM (keyboard arrows work in both encodings at a shell).
/// LOCAL-only: DECRST produces no reply, so nothing is sent to the remote.
const String ghosttyInputModeResetSequence =
    '\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l'
    '\x1b[?1005l\x1b[?1006l\x1b[?1015l'
    '\x1b[?1007l\x1b[?2004l';

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

/// Whether a PRESS at 1-based [row] lands on the tmux STATUS ROW — the last grid
/// row ([gridRows]) — where it must CLICK (switch window / select pane) rather
/// than start a text selection (#971).
///
/// Root cause of "tmux window switch does nothing": under mouse mode a firm
/// status-bar tap (a tap aimed at the small bottom-of-screen status line dwells
/// past the long-press deadline) resolved as a `longpress-select`, so
/// `onMouseReport` never ran and no SGR click reached tmux — device telemetry
/// showed 120 `longpress-select` events and `sentSgrTraceEventCount: 0`. A one-
/// line status bar has nothing to text-select, and the tap path ALREADY treats
/// `row >= gridRows` as the status row (control-mode `select-window`), so the
/// long-press router applies the SAME rule: a press that STARTS on the status
/// row clicks through. Selection is unchanged everywhere else — a press starting
/// on a content row still selects, and a body drag that crosses onto the status
/// row still extends (the decision is made from the START cell). Pure.
bool ghosttyPressIsStatusRowClick({required int row, required int gridRows}) =>
    gridRows > 0 && row >= gridRows;

/// Whether a LONG-PRESS should show the URL Copy/Open action menu instead of
/// starting a selection (#734).
///
/// #726 wired single-tap-to-copy on the ghostty (default) terminal, but the
/// long-press → Copy/Open menu (`showUrlActions` / url_action_overlay.dart) was
/// only wired into the xterm branch. #734 wires it into the ghostty long-press:
/// on a long-press the router hit-tests the press cell against the SAME detected
/// match tap-copy uses (`urlAtCell` → `controller.matchAt`, #767).
/// If a URL is at the cell ([urlAtCell] non-null) the router shows the action menu
/// and SUPPRESSES the #705/#706 selection for that gesture; otherwise the existing
/// long-press selection starts unchanged. So the URL hit-test WINS over selection.
///
/// This trivial predicate factors the decision out of the widget so it's
/// unit-testable headless (and names the rule at the call site). Pure.
bool ghosttyLongPressShowsUrlMenu(StructuredMatch? urlAtCell) =>
    urlAtCell != null;

/// Whether a LONG-PRESS should show the PATH Open/Copy action menu instead of
/// starting a selection (#778, paths Slice 1).
///
/// Mirrors [ghosttyLongPressShowsUrlMenu]: a long-press on a detected absolute
/// file path ([matchAtCell] non-null AND its [StructuredMatch.patternId] is
/// `path`) shows the path action menu (`showPathActions`) and SUPPRESSES the
/// selection for that gesture. A URL/OSC-8 match is NOT a path, so this returns
/// false for those (the URL menu owns them) — the two are mutually exclusive at
/// a single cell. Pure, so the routing decision is unit-testable headless.
bool ghosttyLongPressShowsPathMenu(StructuredMatch? matchAtCell) =>
    matchAtCell != null &&
    (matchAtCell.patternId == kGhosttyPathPatternId ||
        // #1036: a VERIFIED relative-path anchor gets the same path menu
        // (unverified ones never reach a long-press — the visibility gate
        // suppresses their hit-test entirely).
        matchAtCell.patternId == kGhosttyRelPathPatternId);

/// Whether a detected [match]'s payload is a real, copyable string (#810).
///
/// The tap-copy path (`_onMatchTap`) writes `'${match.payload}'` to the clipboard
/// and shows a "Copied URL" toast. If the payload stringifies to empty (or
/// whitespace only) — the #810 device bug, where an empty-URI OSC-8 link
/// produced a non-null match with no payload — the toast would claim success
/// while the clipboard stayed empty. This predicate gates the copy so an empty
/// payload neither writes the clipboard nor toasts. Pure, unit-testable headless.
bool ghosttyMatchHasCopyablePayload(StructuredMatch match) =>
    '${match.payload}'.trim().isNotEmpty;

/// #988: the tap-COPY action for a detected structured match — copies the exact
/// anchor payload (wrap-joined, indent-aware; the #925/#928 extraction). The
/// bubble is the visual preview of exactly this text, so what you see is what
/// a tap copies. Since #999 the single tap only routes URLs/OSC-8 here (path
/// taps NAVIGATE — see [ghosttyTapMatchAction]); the path branch stays because
/// menu-driven copies may still label a path payload.
///
/// Returns the success toast label, or null when nothing was copied (empty
/// payload — the #810 guard — or the [copy] sink failed). [copy] is injected
/// (production: `copyToClipboard`) so the dispatch is unit-testable headless.
Future<String?> ghosttyTapCopyMatch(
  StructuredMatch match, {
  required Future<bool> Function(String text) copy,
}) async {
  // #810: never report a successful copy for an EMPTY payload. An empty-URI
  // OSC-8 link could surface a non-null match with no payload; copying ""
  // while toasting success is the "copied but empty" bug. Bail silently (no
  // clipboard write, no toast) so the tap is a no-op rather than a lie.
  if (!ghosttyMatchHasCopyablePayload(match)) return null;
  final ok = await copy('${match.payload}');
  if (!ok) return null;
  // #1031 slice 3: a user-defined pattern's payload is neither a URL nor a
  // path — the toast says what actually happened.
  if (isCustomPatternId(match.patternId)) return 'Copied match';
  return match.patternId == kGhosttyPathPatternId ? 'Copied path' : 'Copied URL';
}

/// #999: the file-browser TARGET directory for a tapped detected path — the
/// pure dir-vs-file rule.
///
/// Without an SFTP stat we cannot cheaply know whether a detected path names a
/// directory or a file (#990 is building stat infrastructure; a follow-up can
/// refine this on top of it). V1 rule:
///   * a TRAILING SLASH plausibly names a dir → open it directly (normalized,
///     trailing slashes stripped);
///   * anything else — an extension-like final segment or a bare segment we
///     can't classify — opens the PARENT dir, where the tapped entry is still
///     one tap away in the listing.
/// Root (`/`) and degenerate inputs (empty/whitespace) resolve to `/`. Pure,
/// unit-testable headless.
String ghosttyPathBrowseTarget(String path) {
  var p = path.trim();
  final hadTrailingSlash = p.endsWith('/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  if (p.isEmpty || p == '/') return '/';
  if (hadTrailingSlash) return p;
  final cut = p.lastIndexOf('/');
  if (cut <= 0) return '/';
  return p.substring(0, cut);
}

/// #994: the bare REMOTE path a file:// url/osc8 match names, or null when
/// [match] is not file-URL-class.
///
/// Classification is by SCHEME at the ACTION layer — detection is untouched:
/// file:// anchors come from the URL/OSC-8 patterns (`ls --hyperlink` / eza
/// emit OSC-8 file:// links). Because they are URL-pattern matches, they are
/// NOT subject to the #990 single-segment path suppression — an explicit
/// file:// scheme is explicit intent. A `path`-pattern match returns null (it
/// already has the path action set); a malformed file:// payload returns null
/// so the caller falls back to plain-URL handling.
String? ghosttyFileUrlPath(StructuredMatch match) {
  if (match.patternId != kGhosttyUrlPatternId &&
      match.patternId != kGhosttyOsc8PatternId) {
    return null;
  }
  return fileUrlToRemotePath('${match.payload}');
}

/// #999: the single-TAP dispatch for a detected structured match — a PATH
/// anchor NAVIGATES (opens this app's SFTP file browser via the injected
/// [openPath] seam; the #632/#950 favorites → browser entry point), everything
/// else (URL/OSC-8) keeps #988's tap-copy via [ghosttyTapCopyMatch]. The owner
/// verdict on #988's tap=copy-for-both: paths must navigate (the #778
/// behaviour class); copy stays one interaction away on the long-press menu
/// and the gutter mark.
///
/// #994: a url/osc8 match whose payload is a well-formed file:// URI is a
/// REMOTE PATH on the session's host — it NAVIGATES through the same [openPath]
/// seam with the authority-stripped, percent-decoded bare path.
///
/// Returns the copy toast label for the copy branch; null for the navigate
/// branch (the pushed browser IS the feedback) and for an empty payload (the
/// #810 guard applies to both kinds). Both sinks are injected so the dispatch
/// is unit-testable headless.
Future<String?> ghosttyTapMatchAction(
  StructuredMatch match, {
  required Future<bool> Function(String text) copy,
  required Future<bool> Function(String path) openPath,
  String Function(String relative)? resolveRelative,
}) async {
  if (match.patternId == kGhosttyPathPatternId) {
    if (!ghosttyMatchHasCopyablePayload(match)) return null;
    await openPath('${match.payload}'.trim());
    return null;
  }
  // #1036: a RELATIVE path anchor navigates with RESOLVED-ABSOLUTE semantics
  // (the #999 rule applied to the cwd-resolved path). The resolver is injected
  // (production: the session's SessionCwdTracker) so this stays pure; a tap
  // can only arrive on a VERIFIED anchor (the #990-style visibility gate
  // suppresses hit-testing otherwise), so the resolved path exists.
  if (match.patternId == kGhosttyRelPathPatternId) {
    if (!ghosttyMatchHasCopyablePayload(match)) return null;
    final relative = '${match.payload}'.trim();
    await openPath(resolveRelative?.call(relative) ?? relative);
    return null;
  }
  final filePath = ghosttyFileUrlPath(match);
  if (filePath != null) {
    await openPath(filePath);
    return null;
  }
  return ghosttyTapCopyMatch(match, copy: copy);
}

/// The structured-text patterns to register on the controller for [detection]
/// (#888 Part A gating, #998 slice C). PURE — the registration list is the
/// whole per-type gating contract, so a unit test can assert exactly which
/// patterns each toggle adds/removes without an FFI terminal.
///
/// URLs (#767 Slice B): the OSC-8 hyperlink source is the PRIMARY, exact URL
/// source ALONGSIDE the regex `url` pattern. The scanner runs both and an
/// OSC-8 match WINS over an overlapping regex one, so a hyperlinked URL yields
/// ONE exact anchor spanning all its wrapped rows; a plain-text URL still
/// falls to the regex pattern. The URL toggle gates BOTH sources (one
/// user-facing "URLs" type). #864: both carry the EMPTY highlight style (no
/// fill, no underline) so the bubble decorator is the SINGLE affordance.
///
/// Paths (#778 Slice 1): absolute file paths get their own decorator and route
/// a tap to the SFTP explorer; `://` contexts are rejected so a URL stays a URL.
///
/// Commands (#998 C): the fork's BLOCK-tier prompt-anchored command-line
/// pattern (default [kDefaultCommandLexicon]). Its affordance is GUTTER-ONLY
/// (no bubble — [kGhosttyCommandPatternId] is not a bubble pattern id) and its
/// inner url/path/osc8 SPAN anchors coexist inside it (slice A tiering).
/// [commandLexicon] (#1031 slice 2) is the Detection Lab's stored lexicon
/// override; null keeps the fork's default list.
///
/// Customs (#1031 slice 3): every ENABLED [customPatterns] entry whose stored
/// source COMPILES registers a SPAN-tier pattern under its own `custom.*` id,
/// carrying the same EMPTY highlight style as the built-ins (#864 — the
/// widget-layer bubble/gutter decorators are the single affordance). The
/// compile is defensive ([compileCustomPatternRegex] never throws): a source
/// that stopped compiling is simply not registered — the lab card shows its
/// error state; the scanner never sees a bad pattern. Gated by the master
/// switch + the #971 kill switch like every built-in type.
List<TextPattern> ghosttyDetectionPatterns(
  DetectionSettings detection, {
  List<String>? commandLexicon,
  List<CustomPattern> customPatterns = const [],
}) => [
  if (detection.detectUrls) ...[
    TextPattern.osc8(
      id: kGhosttyOsc8PatternId,
      style: kGhosttyUrlHighlightStyle,
    ),
    TextPattern.url(id: kGhosttyUrlPatternId, style: kGhosttyUrlHighlightStyle),
  ],
  if (detection.detectPaths) TextPattern.path(id: kGhosttyPathPatternId),
  // #1036: bare relative paths (`a/b`), verification-gated at the widget
  // layer — an anchor is invisible until its cwd-resolved absolute verifies.
  if (detection.detectRelPaths)
    TextPattern.relativePath(id: kGhosttyRelPathPatternId),
  if (detection.detectCommands)
    TextPattern.command(
      id: kGhosttyCommandPatternId,
      lexicon: commandLexicon ?? kDefaultCommandLexicon,
    ),
  if (!kDetectionDisabled971 && detection.enabled)
    for (final p in customPatterns)
      if (p.enabled)
        if (compileCustomPatternRegex(p.source) case final RegExp regex)
          TextPattern(id: p.id, regex: regex, style: kGhosttyUrlHighlightStyle),
];

/// Whether ANY pattern would register for ([detection], [customPatterns]) —
/// the truth the #921 repaint gating must read. [DetectionSettings.detectionActive]
/// only knows the built-in toggles, so a config with every built-in OFF but a
/// custom pattern ON would otherwise report inactive while a pattern is
/// registered and consuming per-row damage (the #921 stale-paint class).
bool ghosttyDetectionActiveFor(
  DetectionSettings detection,
  List<CustomPattern> customPatterns,
) =>
    detection.detectionActive ||
    (!kDetectionDisabled971 &&
        detection.enabled &&
        customPatterns.any(
          (p) => p.enabled && compileCustomPatternRegex(p.source) != null,
        ));

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

/// The axis a swipe gesture is LOCKED to once it commits (#708).
///
/// #708 root cause: the active overlay used two INDEPENDENT drag recognizers — a
/// `VerticalDragGestureRecognizer` (→ scroll, #690) and a
/// `HorizontalDragGestureRecognizer` (→ window-switch, #702) — competing in the
/// gesture arena. The arena commits to whichever crosses ITS slop first, with no
/// view of the OTHER axis, so a deliberate horizontal swipe with a little vertical
/// jitter could fire the vertical (scroll) recogniser, and a vertical scroll with
/// horizontal drift could trip the horizontal (window-switch) one. The two axes
/// were not mutually exclusive and the off-axis was too sensitive.
///
/// The fix: a SINGLE pan tracker that, once total travel passes a slop, commits to
/// ONE axis (see [ghosttyAxisLock]) and ignores the other for the rest of the
/// gesture. This enum is the commit result the router holds.
enum GhosttySwipeAxis {
  /// Not yet committed — travel below the slop, or the dominant axis does not
  /// clearly exceed the off-axis (a diagonal/ambiguous drag). The router does
  /// NOTHING (no scroll, no window-switch) until the gesture resolves to an axis.
  none,

  /// Committed HORIZONTAL → ONLY the #702 window-switch runs (accumulate dx; emit
  /// one wheel report on lift). Vertical movement is IGNORED — no scroll.
  horizontal,

  /// Committed VERTICAL → ONLY the #690 local scroll runs (drive the scroll
  /// controller from dy). Horizontal movement is IGNORED — no window-switch.
  vertical,
}

/// Decide which axis a swipe of net ([dx], [dy]) logical px commits to (#708).
///
/// PURE axis-lock decision, factored out of the router so it's unit-testable
/// headless. A gesture commits to ONE axis and then ignores the other for its
/// whole duration, making horizontal (tab-switch) and vertical (scroll) mutually
/// exclusive per gesture and insensitive to off-axis jitter:
///
///   - travel below [slop] (`hypot(dx, dy) < slop`) → [GhosttySwipeAxis.none]
///     (don't act on tiny jitter at the very start of a touch);
///   - otherwise the LARGER component is the candidate axis, but it must CLEARLY
///     dominate: `dominant >= ratio * offAxis`. If it does → that axis; if not
///     (a diagonal where neither axis clearly wins) → [GhosttySwipeAxis.none],
///     so the gesture stays uncommitted until it resolves one way.
///
/// The caller commits ONCE: after this returns horizontal/vertical the router
/// holds that lock and does NOT re-ask, so later off-axis drift can never flip a
/// committed gesture. [ratio] ≥ 1 (a value of 1 means "any margin"); the default
/// caller passes [kGhosttySwipeAxisLockRatio]. Uses squared comparisons to avoid
/// a sqrt and stay exact for the slop test.
GhosttySwipeAxis ghosttyAxisLock(
  double dx,
  double dy, {
  required double slop,
  required double ratio,
}) {
  final adx = dx.abs();
  final ady = dy.abs();
  // Below the slop circle → not enough travel to commit yet.
  if (adx * adx + ady * ady < slop * slop) return GhosttySwipeAxis.none;
  if (adx >= ady) {
    // Horizontal candidate: commit only if it clearly exceeds the vertical.
    return adx >= ady * ratio
        ? GhosttySwipeAxis.horizontal
        : GhosttySwipeAxis.none;
  }
  // Vertical candidate: commit only if it clearly exceeds the horizontal.
  return ady >= adx * ratio ? GhosttySwipeAxis.vertical : GhosttySwipeAxis.none;
}

/// Total travel (logical px) a swipe must cross before [ghosttyAxisLock] will
/// commit to an axis (#708). Above the per-update jitter seen in the device
/// gesture log (~1–3px/frame) so a near-still finger never commits, and below
/// [kGhosttyWindowSwitchThreshold] (32px) so a committed-horizontal swipe still
/// needs the full net distance to actually step a window.
const double kGhosttySwipeAxisLockSlop = 12.0;

/// How much the dominant axis must exceed the off-axis for [ghosttyAxisLock] to
/// commit (#708). 1.5× means a swipe within ~34° of pure horizontal/vertical
/// locks to that axis; a steeper diagonal stays uncommitted until it resolves.
/// Tuned with the 14-09-59 device log (real swipes are near-pure-axis: the
/// horizontal swipes there have net dy≈0, so the ratio is easily satisfied).
const double kGhosttySwipeAxisLockRatio = 1.5;

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
/// #708 axis-lock: a SINGLE pan recogniser (not two independent drag recognisers)
/// disambiguates by AXIS. Once total travel passes a slop AND one axis clearly
/// dominates the other (see [ghosttyAxisLock]), the gesture LOCKS to that axis and
/// ignores the off-axis for its whole duration — a horizontal swipe never scrolls
/// on vertical jitter, a vertical scroll never steps a window on horizontal drift.
/// If the finger HOLDS stationary first the long-press recogniser wins (select),
/// because the pan only claims the arena once movement exceeds its slop.
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
/// A gesture ROUTER overlay (#690/#692/#708), made public + `@visibleForTesting`
/// for the #719 swipe smoke test.
///
/// It is `RawGestureDetector` + plain callbacks — NO flterm/libghostty native
/// `.so` is needed to drive it — so a widget test can pump it directly, simulate
/// a horizontal/vertical drag, and assert the synthesised SGR wheel report
/// (`onMouseReport`) lands at the EXPECTED status row, and that a vertical drag
/// scrolls without a report (axis-lock). The swipe→tmux window-switch has
/// regressed repeatedly (#693/#702/#708/#719); this keeps a real drag→report
/// assertion in the gate so a future regression is caught headless. Renamed from
/// the former private `_PointerGestureRouter`.
@visibleForTesting
class GhosttyPointerGestureRouter extends StatefulWidget {
  const GhosttyPointerGestureRouter({
    super.key,
    required this.active,
    required this.scrollController,
    required this.cols,
    required this.rows,
    required this.lastSentCols,
    required this.lastSentRows,
    required this.cellWidth,
    required this.cellHeight,
    required this.mouseTrackingLabel,
    required this.onTap,
    required this.onFocus,
    required this.onMouseReport,
    required this.onSelectionStart,
    required this.onSelectionExtend,
    required this.hasSelection,
    required this.onSelectionClear,
    required this.urlAtCell,
    required this.onUrlTap,
    required this.onUrlLongPress,
    this.controlModeGestures = false,
    this.onWindowSwitch,
    this.onStatusTap,
    this.onScroll,
  });

  /// #911 Part C: when true (the `tmuxControlMode` flag is ON), window switching
  /// is driven by REAL tmux control commands ([onWindowSwitch]/[onStatusTap])
  /// instead of synthesised SGR wheel/click reports at a GUESSED status row — the
  /// fix for the "swipe did nothing / tap hit the wrong row" bugs. The
  /// authoritative active window is read back from `%session-window-changed`, so
  /// the gesture never has to guess geometry. When false (the shipped default) the
  /// existing scrape + synthesised-SGR path runs UNCHANGED.
  final bool controlModeGestures;

  /// #911: a horizontal swipe → next/previous window via a real control command.
  /// Called (instead of [onMouseReport]) only when [controlModeGestures] is true.
  /// [next] = swipe RIGHT (next-window); false = swipe LEFT (previous-window).
  final void Function({required bool next})? onWindowSwitch;

  /// #911: a tap on the status-bar ROW → `select-window` for the tapped window
  /// via a real control command. Carries the 1-based tap [col] and the status
  /// line width [totalCols] so the host can map col → window with no pixel guess.
  /// Called (instead of the SGR click) only when [controlModeGestures] is true
  /// AND the tap landed on the status row.
  final void Function({required int col, required int totalCols})? onStatusTap;

  /// #906 Stage 2: a vertical swipe → scroll the tmux scrollback via a real
  /// `capture-pane` history request. Called (INSTEAD of the local [_applyScroll])
  /// only when [controlModeGestures] is true. [deltaLines] is a signed line delta
  /// — positive scrolls BACK into history (a downward swipe), negative toward
  /// live. Control mode gets no `%output` for copy-mode scroll, so the local
  /// scrollback is near-empty; the host captures the history window instead.
  final void Function(int deltaLines)? onScroll;

  /// Whether to intercept touch (the remote has mouse tracking on).
  final bool active;

  /// The SAME controller handed to the flterm [TerminalView] — moving it routes
  /// through flterm's `_onScrollChanged` → wheel reports / local scroll.
  final TerminalScrollController scrollController;

  /// Live grid columns/rows (from `controller.onResize`) for pixel->cell mapping.
  /// Used ONLY for the touch->cell map (tap click / long-press selection), where
  /// the live grid IS the right coordinate space (flterm renders at this size).
  final int cols;
  final int rows;

  /// The cols/rows LAST SENT to the PTY via `proxy.sendResize` — i.e. the grid
  /// tmux actually BELIEVES it has (#719). The window-switch wheel targets the
  /// status row of THIS, not the live [rows]: on a keyboard toggle / resize the
  /// live grid can change (e.g. 28→47) before tmux is told, so a wheel at the
  /// live status row (47) misses tmux's real status row (28) → no window switch.
  /// Targeting the last-sent rows lands the wheel on tmux's actual status line
  /// even mid-resize. Kept in sync by the parent's single `_sendResize` helper.
  final int lastSentCols;
  final int lastSentRows;

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

  /// Whether a selection is currently active (`controller.selection != null`),
  /// read live so a TAP can DISMISS it (#706, issue 2). The parent owns the
  /// controller, so it supplies this as a getter evaluated at tap time.
  final bool Function() hasSelection;

  /// Clear the active flterm LOCAL selection (`controller.clearSelection()`),
  /// invoked when a TAP lands while a selection is active (#706, issue 2). The
  /// tap is then SWALLOWED — no SGR click / type is forwarded.
  final VoidCallback onSelectionClear;

  /// #726/#767: resolve a 0-based viewport ([col], [row]) cell to the structured
  /// match it lands in, or null. The detection now lives INSIDE the terminal
  /// (#767), so the parent answers this live at tap time via
  /// `controller.matchAt(...)` — no app-side URL list. [StructuredMatch.payload]
  /// is the URL string for the built-in `url` pattern.
  final StructuredMatch? Function(int col, int row) urlAtCell;

  /// #726: copy the tapped URL (a single-tap on a highlighted URL copies it +
  /// shows a top-toast). When a tap lands on a URL the gesture is SWALLOWED —
  /// no #693 SGR click / focus / type is forwarded — exactly like the #706
  /// selection-dismiss path.
  final void Function(StructuredMatch match) onUrlTap;

  /// #734: a LONG-PRESS that lands on a detected URL shows the Copy/Open action
  /// menu (`showUrlActions`) instead of starting a selection. The parent builds
  /// the highlight rects + anchor and calls `showUrlActions`; [match] is the URL
  /// at the pressed cell and [globalAnchor] is the long-press global position the
  /// menu anchors near. When this fires the selection gesture is SUPPRESSED for
  /// the rest of the long-press (no `onSelectionStart`/`onSelectionExtend`), so
  /// the URL hit-test WINS over the #705/#706 selection. Off any URL this never
  /// fires and selection starts as today.
  final void Function(StructuredMatch match, Offset globalAnchor)
  onUrlLongPress;

  @override
  State<GhosttyPointerGestureRouter> createState() =>
      _GhosttyPointerGestureRouterState();
}

class _GhosttyPointerGestureRouterState
    extends State<GhosttyPointerGestureRouter> {
  /// #708: ONE pan tracker replaces the old independent Vertical/Horizontal drag
  /// recognisers so a gesture commits to a SINGLE axis and ignores the other for
  /// its whole duration. State across the pan:
  ///   - [_panDx]/[_panDy]: net travel since pan-start, fed to [ghosttyAxisLock]
  ///     while still uncommitted ([_axis] == none);
  ///   - [_axis]: the committed axis (none until travel passes the slop AND one
  ///     axis clearly dominates). Once horizontal/vertical it is NOT re-evaluated
  ///     — off-axis drift can never flip it;
  ///   - [_windowSwitchDx]: net horizontal travel accumulated ONLY after a
  ///     horizontal commit, evaluated once on lift for the #702 window-switch.
  double _panDx = 0;
  double _panDy = 0;
  GhosttySwipeAxis _axis = GhosttySwipeAxis.none;
  double _windowSwitchDx = 0;

  /// #734: true while the IN-PROGRESS long-press landed on a detected URL and so
  /// drives the Copy/Open action menu instead of a selection. Set in
  /// [_onLongPressStart] when the pressed cell hits a URL; while true the
  /// move/end handlers do NOT extend/finish a selection (the menu owns the
  /// gesture). Reset on every long-press-start so a later off-URL press selects
  /// normally.
  bool _longPressOnUrl = false;

  /// #971: true while the IN-PROGRESS long-press STARTED on the tmux status row
  /// and so was routed as a window-switch CLICK (via [_forwardClickAt]) instead
  /// of a text selection. Like [_longPressOnUrl], while it is true the move/end
  /// handlers do NOT extend/finish a selection (the click already fired on
  /// start). Reset on every long-press-start so a later content-row press
  /// selects normally.
  bool _longPressAsStatusClick = false;

  void _onPanStart(DragStartDetails details) {
    _panDx = 0;
    _panDy = 0;
    _axis = GhosttySwipeAxis.none;
    _windowSwitchDx = 0;
    _scrollAccumPx = 0;
  }

  /// Whether a vertical swipe drives the tmux `-CC` scrollback (#906 Stage 2)
  /// instead of the local flterm scroll: only under the control-mode flag with a
  /// wired [onScroll]. The scrape path (flag OFF) keeps [_applyScroll] unchanged.
  bool get _useControlScroll =>
      widget.controlModeGestures && widget.onScroll != null;

  /// Accumulated vertical finger travel (px) not yet converted to whole lines
  /// (#906 Stage 2). Reset on every pan start.
  double _scrollAccumPx = 0;

  /// Convert a vertical finger delta to whole tmux line scrolls and emit them via
  /// [onScroll] (#906 Stage 2). A downward swipe (dy > 0) scrolls BACK into
  /// history (older); upward scrolls toward live. Sub-cell travel accumulates so
  /// a slow drag still scrolls once it crosses a full cell height.
  void _controlScroll(double fingerDy) {
    final ch = widget.cellHeight;
    if (ch <= 0) return;
    _scrollAccumPx += fingerDy;
    final lines = (_scrollAccumPx / ch).truncate();
    if (lines == 0) return;
    _scrollAccumPx -= lines * ch;
    widget.onScroll!(lines);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final dx = details.delta.dx;
    final dy = details.delta.dy;
    if (_axis == GhosttySwipeAxis.none) {
      // Still disambiguating: accumulate raw travel and ask the pure helper
      // whether the gesture has committed to an axis yet.
      _panDx += dx;
      _panDy += dy;
      _axis = ghosttyAxisLock(
        _panDx,
        _panDy,
        slop: kGhosttySwipeAxisLockSlop,
        ratio: kGhosttySwipeAxisLockRatio,
      );
      if (_axis == GhosttySwipeAxis.none) return;
      // On the commit frame, seed the per-axis accumulator with the travel so
      // far so the first committed update isn't lost.
      if (_axis == GhosttySwipeAxis.horizontal) {
        _windowSwitchDx = _panDx;
      } else if (_useControlScroll) {
        _controlScroll(_panDy); // #906 Stage 2: drive the tmux scrollback
      } else {
        _applyScroll(_panDy);
      }
      return;
    }
    // Committed: run ONLY the locked axis; the off-axis component is ignored.
    if (_axis == GhosttySwipeAxis.horizontal) {
      _windowSwitchDx += dx; // accumulate for the on-lift window-switch
    } else if (_useControlScroll) {
      _controlScroll(dy); // #906 Stage 2: drive the tmux scrollback
    } else {
      _applyScroll(dy); // drive the local scrollback
    }
  }

  /// On lift, finalise the committed axis (#708). A horizontal commit may emit
  /// ONE window-switch wheel report (#702); a vertical commit already scrolled
  /// per-update; an uncommitted gesture (jitter/diagonal below the ratio) does
  /// nothing but is still traced so a device repro shows why it didn't act.
  void _onPanEnd(DragEndDetails details) {
    final axis = _axis;
    final totalDx = axis == GhosttySwipeAxis.horizontal
        ? _windowSwitchDx
        : _panDx;
    final totalDy = _panDy;
    _axis = GhosttySwipeAxis.none;
    _windowSwitchDx = 0;
    _panDx = 0;
    _panDy = 0;
    if (axis != GhosttySwipeAxis.horizontal) {
      // Vertical (scrolled live) or uncommitted: nothing to emit on lift. Trace
      // the net travel + committed axis so a device repro shows the decision.
      _trace('swipe-${axis.name}', totalDx, totalDy, null, null, null);
      return;
    }
    final decision = ghosttyWindowSwitchForSwipe(
      totalDx,
      kGhosttyWindowSwitchThreshold,
    );
    if (decision == GhosttyWindowSwitch.none) {
      // Committed horizontal but below the window-switch distance — record the
      // (sub-threshold) dx so a device repro shows the swipe was seen.
      _trace('swipe-h', totalDx, 0, null, null, null);
      return;
    }
    // #911 Part C (flag ON): switch windows with a REAL control command
    // (`next-window`/`previous-window`) over the -CC channel instead of a
    // synthesised SGR wheel at a GUESSED status row. tmux steps its own active
    // window and pushes `%session-window-changed` (authoritative → repaint), so
    // there is no row to guess and the wrong-row bug cannot recur.
    if (widget.controlModeGestures && widget.onWindowSwitch != null) {
      final next = decision == GhosttyWindowSwitch.next;
      _trace('swipe-h', totalDx, 0, null, null, next ? 'next-window' : 'previous-window');
      widget.onWindowSwitch!(next: next);
      return;
    }
    // #719/#723: target the status row of the rows tmux ACTUALLY HAS — flterm's
    // ACTUAL (last-sent) grid via [_gridRows], NOT the live local grid
    // (widget.rows). On a keyboard toggle / resize the live grid can change (e.g.
    // 28→47) before tmux is told, so a wheel at the live status row (47) would
    // miss tmux's real status row (28) and no window switch fires. [_gridRows]
    // is the SAME single source of truth the cell map clamps to (#723), falling
    // back to the live rows only before the first resize is sent (can't happen
    // once connected).
    final (col, row) = ghosttyStatusRowCell(rows: _gridRows);
    final report = decision == GhosttyWindowSwitch.next
        ? ghosttySgrWheelDown(col: col, row: row) // swipe RIGHT → next-window
        : ghosttySgrWheelUp(col: col, row: row); // swipe LEFT → previous-window
    _trace('swipe-h', totalDx, 0, col, row, report);
    widget.onMouseReport(report);
  }

  /// Apply a vertical finger delta to the shared scroll controller (#690),
  /// natural-direction + clamped. Used only after a VERTICAL axis commit.
  void _applyScroll(double fingerDy) {
    final controller = widget.scrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    final target = (position.pixels + ghosttyScrollDeltaForSwipe(fingerDy))
        .clamp(position.minScrollExtent, position.maxScrollExtent);
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

  /// #723: the AUTHORITATIVE grid for every gesture decision — flterm's ACTUAL
  /// grid, i.e. the cols/rows LAST SENT to the PTY ([widget.lastSentCols]/
  /// [widget.lastSentRows]), which is what tmux ACTUALLY believes it has.
  ///
  /// Root cause (#723): the gesture router had TWO grid notions — the live
  /// `controller.onResize` grid (`widget.cols`/`widget.rows`) and the grid sent
  /// to the PTY. They normally agree, but a transient onResize (or an overlay-box
  /// artifact: the overlay is the FULL Stack box, bigger than flterm's grid-sized
  /// render box) can leave the live grid AHEAD of what tmux has. Acting on the
  /// live grid then targets a row/col tmux doesn't have — the device repro showed
  /// the wheel at row 56 while tmux's status line was 28/47, so swipe-left
  /// scrolled instead of switching windows. The single source of truth is the
  /// last-SENT grid (#719 already targets it for the wheel); the cell CLAMP must
  /// use it too so a touch never maps past tmux's real grid. Falls back to the
  /// live grid only before the first resize is sent (lastSent == 0), which can't
  /// happen once connected.
  int get _gridCols =>
      widget.lastSentCols > 0 ? widget.lastSentCols : widget.cols;
  int get _gridRows =>
      widget.lastSentRows > 0 ? widget.lastSentRows : widget.rows;

  (int, int) _cellAt(Offset local) {
    return ghosttyCellForPosition(
      dx: local.dx,
      dy: local.dy,
      cellWidth: widget.cellWidth,
      cellHeight: widget.cellHeight,
      // #723: clamp to flterm's ACTUAL (last-sent) grid, not the possibly-ahead
      // live grid, so a touch can never map to a cell tmux doesn't have.
      cols: _gridCols,
      rows: _gridRows,
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
      // #723: log the LIVE onResize grid AND the grid LAST SENT to the PTY side
      // by side. At steady state grid==sent (==tmux); a divergence here IS the
      // #723 bug, and one device report (correlated with the live tmux size)
      // proves convergence. Decisions act on `sent` (the authoritative grid).
      cols: widget.cols,
      rows: widget.rows,
      sentCols: _gridCols,
      sentRows: _gridRows,
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
    // #734: URL hit-test WINS over selection. Map the pressed cell to a detected
    // URL (the SAME 1-based→0-based convention as the tap-copy path, #726). If
    // the press lands ON a URL, show the Copy/Open action menu and SUPPRESS the
    // selection for the rest of this long-press; otherwise start the #705/#706
    // selection unchanged.
    final url = widget.urlAtCell(col - 1, row - 1);
    if (ghosttyLongPressShowsUrlMenu(url)) {
      _longPressOnUrl = true;
      _longPressAsStatusClick = false;
      _trace('longpress-url', local.dx, local.dy, col, row, 'menu');
      widget.onUrlLongPress(url!, details.globalPosition);
      return;
    }
    _longPressOnUrl = false;
    // #971: a long-press that STARTS on the tmux STATUS ROW is a window-switch
    // CLICK, not a text selection. A firm status-bar tap dwells past the long-
    // press deadline (device telemetry: `longpress-select`, sentSgr=0, no
    // switch); a one-line status bar has nothing to select. Only under active
    // mouse mode (the overlay routes clicks) — off the status row selection is
    // unchanged, and a body drag onto the status row still extends (the decision
    // is made from this START cell). Suppresses the move/end selection handlers
    // for the rest of this gesture.
    if (widget.active &&
        ghosttyPressIsStatusRowClick(row: row, gridRows: _gridRows)) {
      _longPressAsStatusClick = true;
      _forwardClickAt(col, row, local.dx, local.dy, 'longpress-status-click');
      return;
    }
    _longPressAsStatusClick = false;
    // #705: drive flterm's LOCAL selection (NOT a tmux SGR drag, which tmux's
    // default copy-and-cancel would clear on release). Anchor a collapsed
    // selection at the pressed cell; the parent adds the scroll offset.
    _trace('longpress-select', local.dx, local.dy, col, row, 'start');
    widget.onSelectionStart(col, row);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    // #734: while the URL menu owns this long-press, a drag must NOT extend a
    // selection (the gesture belongs to the menu). #971: same when the press was
    // routed as a status-row window-switch click.
    if (_longPressOnUrl || _longPressAsStatusClick) return;
    final local = details.localPosition;
    final (col, row) = _cellAt(local);
    // #705: extend the LOCAL selection's END to the dragged cell so the
    // highlight grows under the finger.
    _trace('longpress-select', local.dx, local.dy, col, row, 'extend');
    widget.onSelectionExtend(col, row);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    // #734: a URL-menu long-press has no selection to finalise. #971: neither
    // does a status-row window-switch click (the SGR fired on start).
    if (_longPressOnUrl || _longPressAsStatusClick) {
      _longPressOnUrl = false;
      _longPressAsStatusClick = false;
      return;
    }
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
    final local = details.localPosition;
    // #706 (issue 2): if a selection is ACTIVE, a single tap's primary job is to
    // DISMISS it — clear the selection and SWALLOW the tap (no keyboard raise,
    // no SGR click, no type). The owner then long-presses again to start fresh.
    if (ghosttyTapShouldDismissSelection(hasSelection: widget.hasSelection())) {
      widget.onSelectionClear();
      _trace('tap-dismiss-selection', local.dx, local.dy, null, null, null);
      return;
    }
    // #726: if the tap landed on a detected URL, COPY it and SWALLOW the tap —
    // no #693 SGR click, no focus/keyboard, no type. Checked after the #706
    // selection-dismiss (a selection still clears first) but before the normal
    // tap behaviour. The cell map uses the SAME #723-correct grid as the click.
    final (urlCol, urlRow) = _cellAt(local);
    final url = widget.urlAtCell(urlCol - 1, urlRow - 1);
    if (url != null) {
      _trace('tap-url-copy', local.dx, local.dy, urlCol, urlRow, null);
      widget.onUrlTap(url);
      return;
    }
    // Order: focus + raise the keyboard FIRST so the IME comes up regardless of
    // whether the click forwards (the keyboard is the always-on behaviour).
    widget.onTap();
    if (!ghosttyTapShouldForwardClick(active: widget.active)) {
      _trace('tap', local.dx, local.dy, null, null, null);
      return;
    }
    final (col, row) = _cellAt(local);
    _forwardClickAt(col, row, local.dx, local.dy, 'tap');
  }

  /// Forward a CLICK at the (already-computed) 1-based ([col], [row]) cell — the
  /// #693 tap-click path, extracted so a status-row long-press (#971) reuses the
  /// EXACT same routing. Under the #911 control-mode flag a status-row cell
  /// drives the REAL `select-window` command (the host maps the column to a
  /// window from the authoritative ordered list — no pixel/row guessing) and an
  /// off-status-row cell just focuses; otherwise it synthesises an SGR button-1
  /// click (`CSI<0;col;rowM` then `…m`) so tmux selects the clicked window/pane.
  /// [dx]/[dy] and [traceType] label the gesture-log line.
  void _forwardClickAt(int col, int row, double dx, double dy, String traceType) {
    // #911 Part C (flag ON): a click on the STATUS ROW switches windows via a
    // REAL `select-window` control command. Off the status row control mode does
    // not use a synthesised SGR click.
    if (widget.controlModeGestures && widget.onStatusTap != null) {
      if (row >= _gridRows) {
        _trace(traceType, dx, dy, col, row, 'select-window');
        widget.onStatusTap!(col: col, totalCols: _gridCols);
      } else {
        _trace(traceType, dx, dy, col, row, null);
      }
      return;
    }
    final report = ghosttySgrMousePress(col: col, row: row);
    _trace(traceType, dx, dy, col, row, report);
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
        // #706 (issue 2): even in a plain shell a selection can exist (Select-all
        // / double-/triple-tap), so a tap must DISMISS it first; otherwise raise
        // the keyboard as before. We use onTapUp here too (it carries position
        // for the trace) — the translucent layer still lets the pointer fall
        // through to flterm for its own focus/scroll when no selection is active.
        onTapUp: (details) {
          final local = details.localPosition;
          if (ghosttyTapShouldDismissSelection(
            hasSelection: widget.hasSelection(),
          )) {
            widget.onSelectionClear();
            _trace(
              'tap-dismiss-selection',
              local.dx,
              local.dy,
              null,
              null,
              null,
            );
            return;
          }
          // #726: a single tap on a detected URL copies it + swallows the tap,
          // even in a plain shell (no mouse mode). Same 1-based→0-based cell
          // convention as the active branch.
          final (urlCol, urlRow) = _cellAt(local);
          final url = widget.urlAtCell(urlCol - 1, urlRow - 1);
          if (url != null) {
            _trace('tap-url-copy', local.dx, local.dy, urlCol, urlRow, null);
            widget.onUrlTap(url);
            return;
          }
          widget.onTap();
        },
        child: const SizedBox.expand(),
      );
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        // #708: ONE pan recogniser (touch-only) replaces the old independent
        // Vertical + Horizontal drag recognisers. Those competed in the arena and
        // committed to whichever crossed ITS slop first, blind to the other axis —
        // so a horizontal swipe with vertical jitter could scroll, and a scroll
        // with horizontal drift could step a window. The pan sees BOTH components
        // and AXIS-LOCKS via [ghosttyAxisLock]: once committed, only the locked
        // axis runs (horizontal → #702 window-switch on lift; vertical → #690
        // local scroll), and off-axis drift can't flip it. Touch-only so a real
        // mouse drag still reaches the remote; loses the arena to LongPress when
        // the finger holds first (pan only claims once movement passes its slop),
        // so long-press selection still wins.
        PanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
              () => PanGestureRecognizer(
                supportedDevices: const {PointerDeviceKind.touch},
              ),
              (recognizer) => recognizer
                ..onStart = _onPanStart
                ..onUpdate = _onPanUpdate
                ..onEnd = _onPanEnd,
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

  /// #767: the live flterm controller per sessionId, exposed for the on-emulator
  /// integration test so it can read `controller.highlights` / `matchAt` and
  /// assert the in-terminal URL detection tracks scroll into scrollback. Set when
  /// a view's controller is created (initState) and cleared on dispose. Test-only
  /// — no production code reads it.
  @visibleForTesting
  static final Map<String, TerminalController> debugControllers =
      <String, TerminalController>{};

  /// #903: the live resize coalescer per sessionId, exposed for the on-emulator
  /// integration test so it can read `sendCount` — the number of PTY resizes
  /// ACTUALLY sent — and assert a keyboard-toggle / window-switch burst stays
  /// BOUNDED (one per settled size), not a per-animation-frame storm. Set in
  /// initState, cleared on dispose. Test-only — no production code reads it.
  @visibleForTesting
  static final Map<String, GhosttyResizeCoalescer> debugResizeCoalescers =
      <String, GhosttyResizeCoalescer>{};

  /// #971 gesture-tap-sgr: the live per-session [SessionByteRecorder], exposed so
  /// the on-emulator gesture test can assert whether a status-bar TAP under tmux
  /// mouse mode actually SENT an SGR mouse report (`snapshotSentSgrTrace()`
  /// non-empty). The device telemetry for the "tmux switch does nothing" bug
  /// showed `sentSgrTraceEventCount: 0` while every gesture logged as a
  /// `longpress-select` — i.e. the tap resolved as a selection and no SGR click
  /// reached tmux. This mirrors [debugControllers] / [debugResizeCoalescers]: set
  /// in initState, cleared on dispose. Test-only — no production code reads it.
  /// (The same recorder is also reachable via `byteRecorderFor(sessionId)`; this
  /// keyed handle mirrors the other seams for symmetry.)
  @visibleForTesting
  static final Map<String, SessionByteRecorder> debugByteRecorders =
      <String, SessionByteRecorder>{};

  /// #971 gesture-tap-sgr: the REAL measured flterm cell size per sessionId
  /// (logical px), exposed so the gesture test can map a status-bar window label
  /// column to the exact tap pixel (`padding + (col+0.5)*cellWidth`,
  /// `padding + (row+0.5)*cellHeight`). Set every build where the cell size is
  /// measured, cleared on dispose. Test-only — no production code reads it.
  @visibleForTesting
  static final Map<String, Size> debugCellSizes = <String, Size>{};

  /// #975 grid-race: the grid the gesture router sees THIS frame, as
  /// `[cols, rows, lastSentCols, lastSentRows]`. `rows` is the live keyboard-
  /// aware mirror; `lastSentRows` is what the status-tap SGR actually targets
  /// (`_gridRows`). Exposed so the keyboard-race repro can log, at tap time, the
  /// grid the SGR lands in versus the visible (keyboard-reduced) viewport — the
  /// divergence IS the bug (SGR row misses tmux's real status row). Set every
  /// build, cleared on dispose. Test-only — no production code reads it.
  @visibleForTesting
  static final Map<String, List<int>> debugGrids = <String, List<int>>{};

  /// #990: the live per-session path verifier, exposed so the on-emulator
  /// integration test can assert a printed REAL path upgrades to verified while
  /// a FAKE one stays detected (`isVerified(path)`). Mirrors the other debug
  /// seams: set in initState, cleared on dispose. Test-only.
  @visibleForTesting
  static final Map<String, SessionPathVerifier> debugPathVerifiers =
      <String, SessionPathVerifier>{};

  /// #1036: the live per-session cwd tracker, exposed so the on-emulator
  /// integration test can assert the cwd ladder (OSC 7 / prompt-derived)
  /// tracked a `cd` before resolving a relative anchor. Test-only.
  @visibleForTesting
  static final Map<String, SessionCwdTracker> debugCwdTrackers =
      <String, SessionCwdTracker>{};

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

  /// #719: the cols/rows LAST SENT to the PTY via `proxy.sendResize` — what tmux
  /// actually BELIEVES its grid is. The window-switch wheel (#702) must target
  /// the status row of THIS, not the live `_rows`. Device telemetry: the last
  /// resize sent was rows=28 (a #702 resync), the keyboard toggled so the local
  /// grid grew to 47 and `_rows`→47, but the wheel fired at row 47 while tmux
  /// still had 28 rows → the wheel missed tmux's status line (row 28) and no
  /// window switch fired. Every `proxy.sendResize` goes through [_sendResize],
  /// which updates these, so they can never diverge from what tmux was told.
  /// 0 until the first resize is sent.
  int _lastSentCols = 0;
  int _lastSentRows = 0;

  /// #922: the last keyboard-aware grid the LayoutBuilder submitted (computed
  /// from the box the Scaffold shrank for the keyboard). De-dupes the submit so
  /// an unrelated rebuild (theme cycle, output frame) doesn't re-arm the resize
  /// debounce; -1 (never) until the first layout so the first real grid submits.
  int _lastSubmittedGridCols = -1;
  int _lastSubmittedGridRows = -1;

  /// #734: the REAL flterm cell size last measured in [build] (via
  /// [ghosttyMeasureCellSize]), captured so [_showUrlMenu] can build the URL's
  /// on-screen highlight rects with the SAME geometry the router + highlight
  /// painter use — without re-reading the per-session font providers off-build.
  Size _lastCellSize = Size.zero;

  /// #918: a key on the flterm [TerminalView] so [_forceTerminalRepaint] can locate
  /// the internal [TerminalRenderBox] via the render tree and force a full repaint
  /// after dispatching user input (the input-driven half of the robustness layer).
  final GlobalKey _terminalViewKey = GlobalKey();

  /// #755/#767: the session theme's selection colour, captured in [build] from
  /// the live palette. #767 Slice B: it colours the URL BUBBLE decorator (a
  /// rounded outline, not a fill), recomputed each build so cycling the session
  /// theme recolours the bubble. Defaults to a translucent accent until the first
  /// build sets it.
  Color _lastHighlightColor = const Color(0x335B9BD5);

  /// #955: the per-pattern GUTTER registry. Maps a detected anchor's pattern id
  /// to its right-edge mark + tap dispatch (URL/OSC-8 → the URL action overlay;
  /// path → the path overlay / SFTP explorer via [_openPath]). The
  /// [GhosttyGutterLayer] in [build] groups the controller's live anchors by
  /// viewport row and renders one mark per matched row. `late` so it can capture
  /// the instance [_openPath]. A future pattern (slice 4 custom regex) is a
  /// trivial registry entry — no paint code.
  late final GutterPatternRegistry _gutterRegistry =
      GutterPatternRegistry.standard(
        openPath: _openPath,
        // #994: lets the registry offer "Copy sftp URL" for file:// anchors.
        sftpUrlOf: _sftpUrlFor,
        // #995: "Not a URL" / "Not a file" — persist a detection exception.
        onReportException: _reportDetectionException,
        // #1036: resolves a RELATIVE anchor payload against the live session
        // cwd at ACTION time (the tracker is read fresh on every dispatch).
        resolveRelative: (relative) => _cwdTracker.resolve(relative),
      );

  /// #705: the long-press selection ANCHOR — the 1-based VIEWPORT cell of the
  /// long-press-start, held while the finger drags so each extend rebuilds the
  /// flterm `TerminalSelection` with this fixed start and the moving end. Null
  /// when no selection gesture is in progress.
  int? _selAnchorCol;
  int? _selAnchorRow;

  /// #962: true when the current long-press gesture began in the right-edge
  /// gutter strip — the native text selection is suppressed for it (the gutter
  /// owns line-select there) so the two selections don't both render.
  bool _selStartedInGutter = false;

  /// #706 (issue 1): the scrollback length (`scrollbar.total - .visible`)
  /// captured when the active selection was made, so [_reanchorSelectionOnGrowth]
  /// can detect later EVICTION (a DROP in this length) and shift the selection's
  /// absolute rows to keep the highlight on the same content. Null when no
  /// selection is active.
  int? _selScrollbackLen;

  /// #712: whether a selection is currently active (`controller.selection !=
  /// null`), mirrored from the controller in [_onControllerChanged] so the
  /// bottom-right affordance buttons (Copy + Select-all) show ONLY while a
  /// selection exists and the terminal stays clean otherwise. The controller is
  /// a `ChangeNotifier` that fires on selection set/clear, so the existing
  /// listener drives the rebuild — no second listener.
  bool _hasSelection = false;

  /// #828: the TEXT of the selection captured when the user FINALISED it (a
  /// long-press-drag release, or Select-all). Under tmux mouse mode the remote
  /// redraws ~1/s, so #760's [_invalidateSelectionOnRedraw] clears the live
  /// `controller.selection` within a second — before the user can tap Copy —
  /// while the painted highlight lingers. This snapshot is exactly what the user
  /// saw highlighted, so Copy ([_copySelection]) falls back to it via
  /// [ghosttyEffectiveCopyText] instead of false-negativing "No selection".
  /// Empty when no selection has been finalised, and cleared whenever the
  /// selection is dismissed or a new one begins ([_clearSelection]).
  String _lastSelectionText = '';

  /// #760: set true immediately before a remote PTY-output `controller.write()`
  /// and consumed by the very next [_onControllerChanged], so the controller
  /// notify driven by that write can be distinguished from a notify driven by a
  /// pure LOCAL scrollback scroll (which writes no bytes). When an active
  /// selection's covered content is REDRAWN by remote output (the tmux/alt-screen
  /// case where the absolute-row frame can't self-correct), the selection is
  /// stale and is cleared (see [ghosttySelectionInvalidatedByOutput]). A pure
  /// scroll leaves this false, so the selection is retained and tracks.
  bool _remoteOutputPending = false;

  // #767/#778/#998: the pattern ids registered on the controller live in
  // ghostty_terminal_decorators.dart (kGhostty*PatternId); the registration
  // list itself is the pure [ghosttyDetectionPatterns].

  /// #971: short per-session tag for repaint telemetry so multi-session captures
  /// are ATTRIBUTABLE (which view is stuck vs busy). `host#tail` from the session
  /// id — compact so it doesn't bloat the ring.
  late final String _repaintTag = () {
    final sid = widget.sessionId;
    final host = sid.split(':').first;
    final tail = sid.length > 4 ? sid.substring(sid.length - 4) : sid;
    return '$host#$tail';
  }();

  /// #971: whether THIS view is the active (visible) one. Only the active view's
  /// repaint frames are logged (see the onFrameDebug binding) — a busy background
  /// session on the alt screen otherwise drowns the stuck visible session's
  /// telemetry (the exact conflation that blocked #971's diagnosis). Updated in
  /// [build].
  bool _isActiveView = false;

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

  /// #1072: whether we've seen a `shellReady` tick yet. The FIRST tick is the
  /// initial connect (capability detection is legitimate there); every SUBSEQUENT
  /// tick is a reconnect/revive boundary where we arm the controller's
  /// reconnect-settle window to drop stale auto-replies.
  bool _shellReadySeen = false;

  /// #702: pending delayed re-sync timers from the post-shellReady burst, tracked
  /// so dispose cancels them and a gone widget is never re-synced.
  final List<Timer> _resyncTimers = <Timer>[];

  /// #903: coalesces flterm's per-layout-change `onResize` burst (a keyboard
  /// animation's per-frame regrids, the window-switch reflow blip) into a SINGLE
  /// settled PTY resize. Initialised in [initState] so its [onSettled] callback is
  /// the same single `_sendResize` seam (which records the #719 last-sent grid).
  /// The #666/#702 forced resync calls [GhosttyResizeCoalescer.flushNow] to
  /// bypass the debounce. Cancelled on dispose.
  late final GhosttyResizeCoalescer _resizeCoalescer;

  /// #704: the lifecycle state seen on the previous `ref.listen` tick, so
  /// [ghosttyShouldRefreshOnLifecycle] can detect a transition INTO `resumed`
  /// (and not double-fire on a `resumed → resumed` repeat). Null until the
  /// first tick. NOTE: `ref.listen` already hands us `prev`, but the
  /// StateProvider can re-emit the same value; gating on the transition keeps
  /// the resume burst single-shot.
  AppLifecycleState? _lastLifecycle;

  /// #1085: the last window size seen in build, to detect a WINDOWING transition
  /// (desktop-mode entry, rotation, freeform resize) vs a keyboard toggle. A
  /// soft keyboard changes `viewInsets`, NOT `MediaQuery.size`, so any size delta
  /// here is a real window change — the boundary on which we arm the auto-reply
  /// settle so a re-probed DA/DSR/mouse reply doesn't leak as `?62c` (the #1072
  /// family, un-gated on config-changes because no shellReady fires there).
  Size? _lastWindowSize;

  /// #717: whether THIS connect has already focused the terminal. flterm's
  /// `TerminalView` is `autofocus: false`, so on first connect the terminal is
  /// unfocused and flterm scroll/interaction is inert until a tap raises the
  /// keyboard (which focuses it). We `requestFocus()` ONCE per connect (focus
  /// only, NOT showKeyboard — the IME must not auto-pop) when this is the active
  /// session's view, gated by [ghosttyShouldFocusOnConnect]. Set true after the
  /// focus fires; reset false on disconnect so a reconnect re-focuses.
  bool _focusedThisConnect = false;

  /// #790: per-session byte + scroll recorder (replay-harness trace producer).
  /// Captures the raw bytes that reach the terminal and the scroll-offset events
  /// into a bounded backward-looking ring, snapshotted into the bug report so a
  /// scrollback-render bug can be replayed (#791). Allocation-light: stores the
  /// existing output Uint8List + a timestamp, no copy on the hot path.
  late final SessionByteRecorder _byteRecorder = registerByteRecorder(
    widget.sessionId,
  );

  /// Paint-stack boundary counters (paint replay harness). bytesIn/writeErrors
  /// are incremented at the single proxy.output → controller.write seam below;
  /// the render-box counters are probed live via [_probePaintBox]. Snapshotted
  /// into the bug-report payload so a "paint not happening" report names the
  /// broken layer (owner report 2026-07-08T00-51-01).
  late final GhosttyPaintStats _paintStats = registerPaintStats(
    widget.sessionId,
  );

  /// #790: track the last scroll offset pushed to the recorder so a controller
  /// notify that didn't move the viewport (mouse-mode / selection / redraw)
  /// doesn't spam the scroll ring with identical offsets.
  int _lastRecordedScrollOffset = -1;

  /// #990: the per-session detected-path VERIFICATION cache. Feeds the bolder
  /// "verified" shade on the gutter chip + inline bubble for a path anchor
  /// that exists on the CONNECTED host (one SFTP stat per path, debounced,
  /// TTL-cached, fail-open). Scoped to this view == this session, so a path
  /// verified on host A never bleeds onto host B. Null when the proxy failed
  /// to resolve.
  SessionPathVerifier? _pathVerifier;

  /// #990: subscription routing [SftpStatResultEvent]s (broadcast, shared with
  /// the file browser's listener) into [_pathVerifier]. Cancelled on dispose.
  StreamSubscription<SshTaskEvent>? _sftpStatSub;

  /// #1036: per-session working-directory tracker (OSC 7 > prompt-derived >
  /// last-known > home). Refreshed lazily in [_notePathAnchors] whenever a
  /// relative-path anchor is live; read by the visibility gate / tap / menu
  /// dispatch to resolve a relative payload to the absolute path the #990
  /// verifier keys on. Scoped to this view == this session, like the verifier.
  final SessionCwdTracker _cwdTracker = SessionCwdTracker();

  @override
  void initState() {
    super.initState();
    final proxy = _resolveProxy();
    if (proxy == null) {
      _initError = 'No session for ${widget.sessionId}';
      return;
    }
    _proxy = proxy;
    // #903: the coalescer's send seam is `_sendResize` (which records the #719
    // last-sent grid + writes the PTY). Created before `controller.onResize` is
    // wired so the first resize is debounced too.
    _resizeCoalescer = GhosttyResizeCoalescer(
      onSettled: _sendResize,
    );
    // #903 (test-only): expose the coalescer so the emulator integration test
    // can read `sendCount` and assert the resize count is BOUNDED.
    GhosttyTerminalView.debugResizeCoalescers[widget.sessionId] =
        _resizeCoalescer;
    try {
      final controller = TerminalController();
      // Keystrokes (controller.onOutput) -> SSH stdin. Gate on a LIVE session,
      // mirroring the xterm path in sessions.dart: a dead PTY drops input
      // rather than landing escape/mouse bytes as literal text on a re-opened
      // shell.
      controller.onOutput = (bytes) {
        if (proxy.data.state != SshSessionState.connected) return;
        final sent = _applyArmedCtrlToKeystroke(bytes);
        // #793: record this only if it's a synthesized mouse/wheel SGR report —
        // the recorder FILTERS to SGR-mouse bytes, so a typed keystroke (incl. a
        // password at a prompt) is dropped here and NEVER recorded. In tmux mouse
        // mode the local scroll is wheel-SGR that flterm emits through onOutput,
        // so this is the seam that reveals "swipe → wheel events → tmux scrolled".
        _byteRecorder.recordSentSgr(sent);
        proxy.sendInput(sent);
        // #918: force a full re-snapshot + repaint after dispatching this input
        // (soft-keyboard key, IME commit, paste, keybar key — all flow through
        // controller.onOutput). The UI self-heals on every keystroke even if the
        // damage/frame path dropped the redraw. Coalesced to once per frame.
        _forceTerminalRepaint();
      };
      // #1072 (telemetry, additive): TEE the terminal's own AUTO-REPLIES
      // (DA/DSR/CPR/XTVERSION/OSC answers flterm writes back through
      // `onWritePty`) into the diagnostics ring. This is a PURE observer — the
      // reply still forwards through the controller's onOutput seam above
      // exactly as before — so it changes nothing that reaches the SSH stream;
      // it only lets a bug report show a spurious/duplicated DA reply (#1072).
      // User keystrokes never reach onTerminalReply (they bypass onWritePty), so
      // no typed content can enter this ring.
      controller.onTerminalReply = _byteRecorder.recordTermReply;
      // Grid resize. flterm reports (cols, rows) from its OWN layout; we RECORD
      // it for the replay harness but do NOT let it write _cols/_rows or the PTY.
      controller.onResize = (cols, rows) {
        // #790: record the live viewport grid so the replay harness can lay out
        // the captured byte stream at the SAME cols×rows the bug occurred at.
        _byteRecorder.recordGrid(cols, rows);
        // #975: flterm's onResize is NO LONGER a writer of _cols/_rows (nor the
        // PTY). It USED to mirror (cols, rows) here synchronously, but flterm
        // fires onResize from its own layout, which under the soft-keyboard
        // show/hide animation RACES and can settle BACK to the pre-keyboard tall
        // size (device capture 2026-06-25T18-09-02: grid=58x57 while the visible
        // box was keyboard-reduced to ~34 rows). That stale write CLOBBERED the
        // keyboard-aware mirror, and once [_submitKeyboardAwareGrid]'s
        // `_lastSubmittedGridRows` guard had latched the correct size it could not
        // re-correct — leaving `_rows` (the gutter-selection row clamp + gesture
        // geometry) and the status-tap target stale vs the VISIBLE viewport (the
        // "selection cut off at the keyboard line" + "status tap wrong row"
        // symptoms). The SINGLE SOURCE OF TRUTH for _cols/_rows AND the PTY grid
        // is now the keyboard-aware grid computed from the laid-out (keyboard-
        // reduced) box in the LayoutBuilder ([_submitKeyboardAwareGrid] → the
        // #903 coalescer). The #767 in-terminal URL re-detect still runs on the
        // controller's own notify cycle.
      };
      // PTY output bytes -> terminal. The subscription lives on this state so
      // dispose() cancels it.
      _outputSub = proxy.output.listen((bytes) {
        try {
          // #790: record the raw output chunk BEFORE writing it to the terminal
          // — this is the single seam where proxy.output bytes reach the
          // Terminal, so the recorder captures EXACTLY the input that produced
          // the rendered (possibly buggy) state. Allocation-light: the recorder
          // keeps the reference + a timestamp; no copy/encode here.
          _byteRecorder.recordBytes(bytes);
          // Paint replay harness: count the chunk at the write seam BEFORE the
          // write, so bytesIn reflects what was DELIVERED even if write throws.
          _paintStats.bytesInChunks++;
          _paintStats.bytesInTotal += bytes.length;
          // #760: mark that the imminent controller notify is driven by fresh
          // REMOTE output (not a local scroll), so _onControllerChanged can
          // invalidate a selection whose covered content was just redrawn.
          _remoteOutputPending = true;
          controller.write(bytes);
        } catch (e) {
          // Defensive — a single PTY byte must never crash the session. But a
          // silently-throwing write is indistinguishable from a healthy one on
          // a stale screen, so COUNT it and (bounded) log the first few — the
          // paint replay harness / bug report reads writeErrors to rule this
          // layer in or out.
          _paintStats.writeErrors++;
          if (_paintStats.writeErrors <= 3) {
            clifecycle('repaint', '$_repaintTag controller.write threw: $e');
          }
        }
      });
      // Track remote mouse-mode changes so the #690 swipe-scroll overlay turns
      // on/off as the remote toggles mouse reporting (e.g. tmux mouse on/off).
      controller.addListener(_onControllerChanged);
      _mouseTracking = controller.mouseTracking;
      _controller = controller;
      // #767 (test-only): expose this controller so the on-emulator integration
      // test can assert the in-terminal URL detection tracks scroll/eviction.
      GhosttyTerminalView.debugControllers[widget.sessionId] = controller;
      // #971 (test-only): expose the sent-SGR recorder so the gesture test can
      // assert a status-bar tap actually forwarded an SGR mouse click to tmux.
      GhosttyTerminalView.debugByteRecorders[widget.sessionId] = _byteRecorder;
      // #1074: the detection WASH is a LIVE widget LAYER ([GhosttyWashLayer])
      // painted UNDER the transparent terminal — NOT the fork's highlight pass.
      // So the app installs NO `detectionHighlightStyleOf` resolver: the fork's
      // HighlightPainter draws nothing for detection (registration is colourless
      // below), and the wash tracks live off the controller's anchor set every
      // build instead of only when the render box repaints (the #1045 frozen-
      // band root cause). Discovery / anchors (#1069/#1071) are untouched.
      // #767: register the built-in URL pattern so the terminal detects URLs
      // over its OWN cells and maintains the anchors across scroll / wrap /
      // resize / eviction. #767 Slice B / #1074: the REGISTRATION carries no
      // fill — the wash is painted by the widget layer from the live anchors.
      _registerUrlPattern(controller);
      // #990: per-session path verification. The verifier probes each detected
      // path anchor ONCE (debounced, capped, TTL-cached) over the session's
      // SFTP and the gutter/bubble layers read `isVerified` for the bolder
      // shade. Anchors are noted off the SAME narrow decoration listenable the
      // layers repaint on; results arrive on the broadcast sftpEvents stream.
      _pathVerifier = SessionPathVerifier(
        sessionId: widget.sessionId,
        sendStat: proxy.sftpStat,
      );
      _sftpStatSub = proxy.sftpEvents.listen((event) {
        if (event is SftpStatResultEvent) {
          _pathVerifier?.onStatResult(
            requestId: event.requestId,
            exists: event.exists,
          );
        }
      });
      controller.decorationListenable.addListener(_notePathAnchors);
      // #1074: a verification result changes an anchor's wash (verified alpha,
      // #990 suppressed→visible) with NO anchor change. The wash is now a widget
      // layer that repaints off `_pathVerifier` (passed as the layer's
      // repaintListenable), so no fork re-bake is needed here.
      // #990 (test-only): expose the verifier so the on-emulator integration
      // test can assert the real-path/fake-path shade split.
      GhosttyTerminalView.debugPathVerifiers[widget.sessionId] = _pathVerifier!;
      // #1036 (test-only): expose the cwd tracker so the emulator test can
      // assert the ladder followed a `cd`.
      GhosttyTerminalView.debugCwdTrackers[widget.sessionId] = _cwdTracker;
      // Paint replay harness: let the stats snapshot probe the live render-box
      // boundary counters (notifies / paints / frame syncs) at read time.
      _paintStats.boxProbe = _probePaintBox;
      // #1072 (telemetry, additive): install the detection-geometry probe so the
      // bug report can snapshot this session's live wash offsets + per-anchor
      // rows for the frozen-bubble diagnosis. Read-only.
      registerDetectionGeom(widget.sessionId, _probeDetectionGeom);
      // #702: arm the first-connect resize re-sync on the proxy's shellReady
      // stream. The xterm #666 fit-burst is offstage for ghostty, so this is the
      // ghostty-LOCAL equivalent: once the task-side shell EXISTS, force-re-send
      // the current grid so the size that reaches tmux is the post-layout one,
      // not the pre-shellReady default that gets dropped. Re-fires on reconnect.
      _shellReadySub = proxy.shellReady.listen((_) {
        if (!mounted) return;
        // #1072: a shellReady RE-FIRE (not the first tick) is the reconnect/
        // revive boundary. Arm the terminal's reconnect-settle window so its
        // AUTO-replies (DA/DSR/CPR answers, focus + mouse reports) are DROPPED
        // while tmux is mid-reattach and not consuming them — otherwise its tty
        // echoes them as literal input at the idle prompt (the recurring `?62c`
        // DA leak and stray `[<..M` mouse codes). First connect is untouched so
        // legitimate capability detection there is answered.
        if (_shellReadySeen) {
          controller.beginReconnectSettle();
        }
        _shellReadySeen = true;
        // #1014: a shellReady tick is the REVIVE boundary — the terminal
        // instance survived the reconnect, so re-sync its synthesized-input-
        // gating DEC modes (stale tmux mouse mode kept the SGR path firing
        // into the revived plain shell as literal [<65;...M text). Runs FIRST:
        // shellReady precedes the new shell's output on the shared IPC stream,
        // so a still-alive TUI's re-emitted DECSET re-enables the modes right
        // after — which is exactly why the keybar Reset key exists as a manual,
        // on-demand escape hatch (see [_resetInputModes]).
        _resetInputModes('shellReady');
        // #717: a shellReady tick is a fresh connect (re-fires on reconnect), so
        // reset the per-connect focus latch and re-focus this connect. flterm is
        // autofocus:false, so without this the terminal stays unfocused and its
        // scroll/interaction is inert until a tap raises the keyboard.
        _focusedThisConnect = false;
        _armResizeResync();
        _focusTerminalOnConnect('shellReady');
      });
    } catch (e) {
      // If libghostty's native .so failed to load, surface it instead of a
      // blank crash so the device tester can report it (mirrors the spike).
      _initError = 'flterm init failed: $e';
    }
  }

  /// The controller is a `ChangeNotifier` that fires on output writes, scroll,
  /// mouse-mode toggles, etc. On each notification we (1) re-anchor a persisted
  /// selection to its content if the scrollback evicted lines (#706, issue 1),
  /// then (2) follow the remote's mouse-tracking mode (#690). Re-anchor runs
  /// FIRST and reads the controller directly (no setState), so it doesn't depend
  /// on the mouse-mode rebuild.
  void _onControllerChanged() {
    // #760: consume the remote-output flag for THIS notify before anything else
    // can re-enter. A notify is either a remote write (flag set just before
    // controller.write) or a local event (scroll / mouse-mode / selection set);
    // only the former should invalidate a selection whose content was redrawn.
    final remoteOutput = _remoteOutputPending;
    _remoteOutputPending = false;
    _reanchorSelectionOnGrowth();
    // #760: if a selection is active and this notify was driven by fresh remote
    // output (a tmux/alt-screen redraw replaces the covered rows in place — the
    // absolute-row frame can't track that), clear the now-stale selection. A
    // pure local scrollback scroll (no write → remoteOutput false) is retained.
    _invalidateSelectionOnRedraw(remoteOutput);
    // #790: record a scroll-offset event when the viewport actually moved. This
    // notify fires on scroll AND on output/mouse-mode/selection; only an offset
    // CHANGE is a real scroll, so we de-dupe against the last recorded value to
    // keep the scroll ring a faithful record of the scroll path (#789) without a
    // flood of identical offsets.
    final controller = _controller;
    if (controller != null) {
      final offset = _viewportOffsetOf(controller);
      if (offset != _lastRecordedScrollOffset) {
        _lastRecordedScrollOffset = offset;
        _byteRecorder.recordScroll(offset);
      }
    }
    _syncMouseTracking();
    _syncHasSelection();
    // #767: URL re-detection now lives INSIDE the terminal. The controller
    // re-scans its own cells on this same notify cycle (debounced) and assigns
    // the highlights, so the host no longer schedules or pushes detection — the
    // #748/#750/#751/#764 drift root cause (external re-sync on every notify) is
    // gone.
  }

  /// #990: feed the CURRENTLY-ANCHORED detected paths to the per-session
  /// verifier. Runs on the controller's narrow decoration listenable (fires on
  /// anchor-set / painted-offset changes only). Cheap: the verifier debounces,
  /// dedupes against its TTL cache, and caps in-flight stats — so this can
  /// fire freely on every rescan. Gated on a connected session: probing a
  /// dead session is pure noise (its stats would fail-open anyway).
  void _notePathAnchors() {
    final controller = _controller;
    final verifier = _pathVerifier;
    if (controller == null || verifier == null) return;
    // #1044: while the viewport is actively scrolling this fires PER FRAME
    // (the decoration listenable tracks the painted offset, #993), and when a
    // relative anchor is live each pass re-reads the WHOLE visible viewport
    // text over FFI for the cwd ladder (#1036) — a heavy per-frame tax during
    // a fling. Verification noting is quiesce work: skip mid-scroll; the
    // settle edge fires this listenable once more and that pass notes
    // everything (the verifier's TTL cache absorbs the batching).
    if (controller.isScrolling) return;
    final proxy = _proxy;
    if (proxy == null || proxy.data.state != SshSessionState.connected) return;
    final anchors = controller.anchors;
    // #1036: RELATIVE anchors are noted under their cwd-RESOLVED absolute path
    // — the verifier cache is keyed on the resolved path, so a later `cd`
    // re-resolves to a fresh key that starts pending (hidden) again. Refresh
    // the cwd ladder first, and only when a relative anchor is actually live
    // (the refresh reads controller text — cheap, but not free).
    final hasRelative = anchors.any(
      (a) => a.patternId == kGhosttyRelPathPatternId,
    );
    if (hasRelative) _refreshCwd(controller);
    verifier.notePaths([
      for (final anchor in anchors)
        if (anchor.patternId == kGhosttyPathPatternId)
          '${anchor.payload}'
        else if (anchor.patternId == kGhosttyRelPathPatternId)
          _cwdTracker.resolve('${anchor.payload}'),
    ]);
  }

  /// #1036: refresh the session cwd ladder from the live terminal — the OSC 7
  /// advisory ([TerminalController.pwd], strongest) and the most recent
  /// on-screen strong prompt (`user@host:PATH$`, scanned bottom-up over the
  /// visible rows). Defensive on every FFI read: a hiccup must never crash the
  /// session, and a failed refresh just leaves the sticky last-known cwd (the
  /// #990 verifier absorbs staleness).
  void _refreshCwd(TerminalController controller) {
    try {
      _cwdTracker.noteOsc7(controller.pwd);
    } catch (_) {}
    try {
      // One verbatim viewport read (row 0 = top visible row), scanned
      // BOTTOM-UP: the lowest strong prompt is the current one; rows above it
      // belong to older commands, so stop at the first hit either way.
      final lines = controller
          .visibleRowsText(0, controller.scrollbar.visible - 1)
          .split('\n');
      for (var i = lines.length - 1; i >= 0; i--) {
        if (promptCwd(lines[i]) != null) {
          _cwdTracker.notePromptLine(lines[i]);
          return;
        }
      }
    } catch (_) {}
  }

  /// #990: the OPAQUE verification predicate handed to the gutter + bubble
  /// layers. True only for a PATH anchor whose payload the session verifier
  /// confirmed (exists on the connected host, fresh in its TTL cache). The
  /// layers never learn WHY — the predicate could later mean "downloaded
  /// locally" without any paint change.
  bool _isAnchorVerified(StructuredAnchor anchor) =>
      _isPayloadVerified(anchor.patternId, '${anchor.payload}');

  /// Payload-shaped core of [_isAnchorVerified] — shared with the #1074 wash
  /// layer's colour closure, which gates by anchor payload.
  bool _isPayloadVerified(String patternId, String payload) {
    // #1036: a relative anchor is verified iff its cwd-RESOLVED absolute is —
    // and since the visibility gate hides it otherwise, every VISIBLE relpath
    // anchor renders in the verified shade by construction.
    if (patternId == kGhosttyRelPathPatternId) {
      return _pathVerifier?.isVerified(_cwdTracker.resolve(payload)) ?? false;
    }
    if (patternId != kGhosttyPathPatternId) return false;
    return _pathVerifier?.isVerified(payload) ?? false;
  }

  /// #990 visibility gate (owner report on +121: `/config`, `/rc` bubbled): a
  /// SINGLE-SEGMENT root-level path match is a low-confidence detection —
  /// overwhelmingly a TUI slash-command — so it shows NO affordance (no
  /// bubble, no gutter chip, no tap-copy) unless the verifier CONFIRMED it
  /// exists on this host. `pending` and `missing` are both suppressed.
  /// Multi-segment paths (and every non-path pattern) are always visible.
  bool _isPayloadVisible(String patternId, String payload) {
    // #995: a user-reported false positive ("Not a URL" / "Not a file")
    // suppresses this exact matched text — checked FIRST so it composes with
    // (never forks) the #990 verification gate below. O(1) hash-set lookup.
    if (ref
        .read(detectionExceptionsProvider.notifier)
        .isSuppressed(patternId, payload)) {
      return false;
    }
    // #1036: a RELATIVE-path anchor is suppressed until its cwd-RESOLVED
    // absolute path verifies. Unconditional (no lab knob bypass): hidden-
    // until-verified IS the contract for this class — shape-level recall is
    // deliberately broad (`and/or` matches), the stat is the precision gate.
    // Both `pending` and `missing` stay hidden (hide-on-fail, unlike
    // multi-segment absolutes which show at the detected shade).
    if (patternId == kGhosttyRelPathPatternId) {
      return _pathVerifier?.status(_cwdTracker.resolve(payload)) ==
          PathVerification.verified;
    }
    if (patternId != kGhosttyPathPatternId) return true;
    // #1031 slice 2: the lab's "Short-path verification" knob gates the #990
    // suppression. OFF → single-segment matches show immediately at the
    // detected shade (the pre-#990 behavior, now an explicit user choice).
    final verifyShortPaths = ref
        .read(detectionStylesProvider)
        .of(kGhosttyPathPatternId)
        ?.verifyShortPaths;
    if (verifyShortPaths == false) return true;
    if (!ghosttyPathRequiresVerification(payload)) return true;
    return _pathVerifier?.status(payload) == PathVerification.verified;
  }

  /// Anchor-shaped adapter of [_isPayloadVisible] for the gutter/bubble layers.
  bool _isAnchorVisible(StructuredAnchor anchor) =>
      _isPayloadVisible(anchor.patternId, '${anchor.payload}');

  /// #767: read the flterm viewport scroll offset, defensively (an FFI hiccup
  /// must never crash the session) — 0 if the controller can't report it. Used
  /// to convert the controller's ABSOLUTE-row match ranges to VIEWPORT rows when
  /// laying out the long-press URL menu rects.
  int _viewportOffsetOf(TerminalController controller) {
    try {
      return controller.scrollbar.offset;
    } catch (_) {
      return 0;
    }
  }

  /// #767: register (or re-register) the built-in `url` structured-text pattern
  /// on the controller. The terminal detects URLs over its OWN cells and
  /// maintains the ANCHORS across scroll / wrap / resize / eviction — no app-side
  /// detect or push. Re-registering with the same id replaces the pattern.
  ///
  /// #767 Slice B / #955 / #988 / #1074: the REGISTRATION carries NO highlight
  /// background. The WASH is a LIVE widget layer ([GhosttyWashLayer]) painted
  /// UNDER the transparent terminal, resolved per anchor from the controller's
  /// live anchors; the right-edge GUTTER mark ([GhosttyGutterLayer]) is a
  /// sibling widget layer. Colour comes from the wash layer's closure each
  /// build; this registration is theme-independent.
  void _registerUrlPattern(TerminalController controller) {
    // #888 Part A: detection is gated on the GLOBAL detection settings. Read
    // them HERE so registration reflects the current toggles; a live change
    // re-runs this (after clearTextPatterns) via the build() ref.listen below.
    // Each NOT-registered pattern means zero scan + zero decoration for that
    // type (the controller no-ops on an empty pattern set). Master OFF →
    // register nothing.
    final detection = ref.read(detectionSettingsProvider);
    // #1031 slice 2: the command pattern registers with the lab's stored
    // lexicon override (null = the fork's default list). A lexicon change
    // re-runs this via the build() styles ref.listen.
    final commandLexicon = ref
        .read(detectionStylesProvider)
        .of(kGhosttyCommandPatternId)
        ?.lexicon;
    // #1031 slice 3: user-defined patterns register alongside the built-ins
    // (enabled + compiling only; a change re-runs this via the build()
    // customs ref.listen).
    final customPatterns = ref.read(customPatternsProvider);
    for (final pattern in ghosttyDetectionPatterns(
      detection,
      commandLexicon: commandLexicon,
      customPatterns: customPatterns,
    )) {
      controller.registerTextPattern(pattern);
    }
    // #921: tell the render box whether detection is now active. Active means the
    // controller's detection RenderState handle competes to consume the shared
    // terminal damage, so the PRIMARY screen must force a full re-read on content
    // change to keep repainting. Deferred to a post-frame callback so the keyed
    // render box exists (this runs from initState-time registration before first
    // layout, where the box lookup would no-op). #1031 slice 3: customs count
    // (a custom-only config still competes for the shared damage).
    final detectionActive = ghosttyDetectionActiveFor(
      detection,
      customPatterns,
    );
    // Detection-saga telemetry (#966-era "URLs not detected" report): record what
    // this registration + the SYNCHRONOUS rescan produced so the next bug report
    // is one-shot diagnosable instead of a blind build loop. Cheap; runs on init
    // AND on every settings toggle (the ref.listen re-invokes this).
    //   anchors=0                     → nothing matched (alt-screen heuristic
    //                                   suppression w/o mouse, or the scan window
    //                                   missed the content)
    //   anchors>0, gutterResolved=0   → the #958 class (anchor→viewport-row
    //                                   resolution / mark mount broken)
    //   anchors>0, gutterResolved>0   → marks SHOULD paint (visibility/paint)
    final anchors = controller.anchors;
    var gutterResolved = 0;
    for (final a in anchors) {
      if (a.ranges.any((r) => controller.anchorGutterRow(r) != null)) {
        gutterResolved++;
      }
    }
    ctrace(
      'detect',
      'register url=${detection.detectUrls} path=${detection.detectPaths} '
      'command=${detection.detectCommands} '
      'screen=${controller.activeScreen} mouse=${controller.mouseTracking} '
      'anchors=${anchors.length} gutterResolved=$gutterResolved',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyDetectionActive(detectionActive);
    });
  }

  /// #712: mirror whether a selection is active into [_hasSelection], rebuilding
  /// only when it actually toggles (the controller notifies on many unrelated
  /// events too) so the bottom-right affordance buttons show ONLY while a
  /// selection exists. Runs AFTER [_reanchorSelectionOnGrowth], which may CLEAR a
  /// fully-evicted selection, so this reads the post-re-anchor state.
  ///
  /// #828: a LIVE selection OR a surviving finalised-text snapshot counts. Under
  /// tmux mouse mode #760 clears the live selection ~1/s while the user still
  /// wants to Copy; honoring the snapshot keeps the Copy button on screen (and a
  /// tap still dismisses it) instead of the button vanishing the moment the
  /// status bar ticks.
  void _syncHasSelection() {
    final controller = _controller;
    if (controller == null) return;
    final next = ghosttyHasCopyableSelection(
      liveSelection: controller.selection != null,
      snapshot: _lastSelectionText,
    );
    if (next == _hasSelection) return;
    if (mounted) setState(() => _hasSelection = next);
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

  /// Clear stuck terminal INPUT modes locally (#1014 + the keybar Reset key).
  /// Writes the DECRST reset sequence into the controller — LOCAL only (DECRST
  /// produces no reply, so nothing reaches the remote) — so a stuck
  /// mouse-reporting mode stops synthesising SGR reports from taps. The
  /// controller.write flips `mouseTracking` off, which [_onControllerChanged] →
  /// [_syncMouseTracking] mirrors into `_mouseTracking`, so the tap path stops
  /// emitting codes immediately. Called on the shellReady revive boundary AND
  /// on demand from the keybar Reset key: a still-alive TUI can re-enable modes
  /// right after the auto-reset, so the manual escape hatch is what actually
  /// unsticks a bare prompt without a reconnect.
  void _resetInputModes(String reason) {
    final controller = _controller;
    if (controller == null) return;
    final staleTracking = controller.mouseTracking;
    controller.write(
      Uint8List.fromList(ghosttyInputModeResetSequence.codeUnits),
    );
    ctrace(
      'ui.modes1014',
      '$reason: input-mode reset (mouse was ${staleTracking.name})',
    );
  }

  SshSessionProxy? _resolveProxy() {
    for (final e in ref.read(sessionsProvider).entries) {
      if (e.id == widget.sessionId) return e.proxy;
    }
    return null;
  }

  /// Apply the shared armed keybar Ctrl modifier (#728) to a soft-keyboard
  /// keystroke before it is forwarded to the PTY.
  ///
  /// The keybar's Ctrl key arms [ctrlModifierProvider] (in addition to its own
  /// #694 `CtrlModifier`); there are no letter keys on the keybar, so to send
  /// Ctrl+R the user types R on the soft keyboard — which flterm delivers here as
  /// `controller.onOutput` bytes. When Ctrl is armed we transform the next typed
  /// character to its control byte and CLEAR the one-shot.
  ///
  /// Byte-level care (mirrors [ghosttyApplyArmedCtrl] but stays on bytes so
  /// multi-byte UTF-8 is never round-tripped): only a SINGLE ASCII byte (< 0x80)
  /// can carry a Ctrl-letter meaning, so we decode just that one byte, run the
  /// pure helper, and re-encode the single transformed char. Any multi-byte input
  /// (IME / paste / a CSI escape) passes through UNCHANGED — but the one-shot Ctrl
  /// still clears so it can't get stuck. When Ctrl is NOT armed this is a no-op
  /// fast path returning the original bytes untouched.
  Uint8List _applyArmedCtrlToKeystroke(Uint8List bytes) {
    final notifier = ref.read(ctrlModifierProvider.notifier);
    // One-shot: read+clear. If it wasn't armed, forward the bytes verbatim.
    if (!notifier.consume()) return bytes;
    // Only a single ASCII byte can be a Ctrl-letter; anything else (multi-byte
    // UTF-8 / IME / paste / escape) passes through unchanged.
    if (bytes.length != 1 || bytes[0] >= 0x80) return bytes;
    final result = ghosttyApplyArmedCtrl(
      armed: true,
      bytes: String.fromCharCode(bytes[0]),
    );
    return Uint8List.fromList(result.bytes.codeUnits);
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
    // #970: one-shot ConPTY nudge once the grid has settled (see const).
    _resyncTimers.add(
      Timer(
        const Duration(milliseconds: kGhosttyConPtyNudgeMs),
        _nudgeRemotePtySize,
      ),
    );
  }

  /// #970: force a WINDOW-CHANGE the remote acts on, ONCE per connect. Windows
  /// ConPTY holds its prompt/output until it sees a DIFFERENT size — the #702
  /// same-size resync burst doesn't flush it, so a fresh connect to a Windows
  /// host stays BLANK until the user manually resizes (owner-diagnosed: single-
  /// session, "resize makes it appear"). Send the settled grid at rows-1, then
  /// restore the real rows a beat later. Routed through [_sendResize] with
  /// DIFFERENT sizes so neither push is deduped. Sends only to the REMOTE PTY
  /// (not the local flterm grid), so there's no local resize/flicker; harmless on
  /// Unix hosts (a transient remote re-fit before any TUI is running).
  void _nudgeRemotePtySize() {
    if (!mounted) return;
    final proxy = _proxy;
    if (proxy == null || proxy.data.state != SshSessionState.connected) return;
    final cols = _lastSubmittedGridCols > 0 ? _lastSubmittedGridCols : _cols;
    final rows = _lastSubmittedGridRows > 0 ? _lastSubmittedGridRows : _rows;
    final seq = ghosttyConPtyNudgeSizes(cols, rows);
    if (seq == null) return;
    _sendResize(seq[0].cols, seq[0].rows);
    gtrace('conpty-nudge ${seq[0].cols}x${seq[0].rows} -> ${seq[1].rows} (#970)');
    _resyncTimers.add(
      Timer(const Duration(milliseconds: 80), () {
        if (!mounted) return;
        final p = _proxy;
        if (p == null || p.data.state != SshSessionState.connected) return;
        _sendResize(seq[1].cols, seq[1].rows);
      }),
    );
  }

  /// #702: FORCE-re-send the current grid to the PTY (even if unchanged) so tmux
  /// re-sizes to the post-shellReady layout. Guarded by [ghosttyShouldResyncResize]
  /// (connected + valid grid); a tick with no valid grid is a no-op.
  /// Every forced re-sync is recorded in the gesture/connect trace so a device
  /// repro CONFIRMS a real resize landed after shellReady (`ghostty-resync`).
  ///
  /// #922: re-push the KEYBOARD-AWARE grid ([_lastSubmittedGridCols]/[Rows], the
  /// size the LayoutBuilder computed from the keyboard-reduced box) when it's been
  /// laid out, so the resync delivers the SAME authoritative size the steady-state
  /// path does — never flterm's possibly-stale `_cols`/`_rows`. Falls back to the
  /// live grid only before the first layout (when the keyboard-aware grid is -1).
  void _forceResizeResync(String trigger) {
    if (!mounted) return;
    final proxy = _proxy;
    if (proxy == null) return;
    final connected = proxy.data.state == SshSessionState.connected;
    final cols = _lastSubmittedGridCols > 0 ? _lastSubmittedGridCols : _cols;
    final rows = _lastSubmittedGridRows > 0 ? _lastSubmittedGridRows : _rows;
    if (!ghosttyShouldResyncResize(
      connected: connected,
      cols: cols,
      rows: rows,
    )) {
      gtrace(
        'ghostty-resync $trigger: skip '
        '(connected=$connected cols=$cols rows=$rows)',
      );
      return;
    }
    // #903: a forced resync must NOT be debounced — it re-pushes the CURRENT
    // size the instant the shell exists (#666/#702), so flush immediately and
    // cancel any pending coalesce. The proxy still owns the #666 one-shot
    // force-bypass of its no-op guard.
    _resizeCoalescer.flushNow(cols, rows);
    gtrace('ghostty-resync $trigger: cols=$cols rows=$rows');
  }

  /// #719: the SINGLE path for every PTY resize. Sends the grid to the proxy AND
  /// records it as the last-sent grid ([_lastSentCols]/[_lastSentRows]) — the
  /// rows tmux now BELIEVES it has. Routing both `onResize` and the #702 forced
  /// resync through here guarantees the window-switch wheel target (which reads
  /// the last-sent rows) can never diverge from what tmux was actually told, so
  /// a horizontal swipe lands on tmux's real status row even mid-resize (the
  /// #719 desync: live grid 47, but tmux still on 28).
  void _sendResize(int cols, int rows) {
    final proxy = _proxy;
    if (proxy == null) return;
    proxy.sendResize(cols, rows);
    final changed = cols != _lastSentCols || rows != _lastSentRows;
    _lastSentCols = cols;
    _lastSentRows = rows;
    // #975: the gesture router + gutter-select layer read _lastSentCols/
    // _lastSentRows (the grid the status-tap SGR targets) and _cols/_rows from
    // THIS widget's build. _sendResize runs off the #903 coalescer's settle Timer
    // (and the #702/#970 resync/nudge timers) — OUTSIDE the build/notify cycle,
    // and plain terminal output does NOT rebuild this widget (_onControllerChanged
    // only setState's on a mouse-mode / selection CHANGE). So after a keyboard-
    // toggle resize SETTLES, the router kept a STALE last-sent grid and a status
    // tap targeted the OLD status row (tmux had already reflowed) → no window
    // switch (#975 "tap wrong row"). Rebuild when the sent grid changes so the
    // tap/selection map to tmux's CURRENT grid. Cheap + can't loop (the
    // LayoutBuilder's _submitKeyboardAwareGrid guard no-ops an unchanged grid, so
    // this never re-triggers a send). Never called during build (Timer/stream
    // callbacks only), so setState is safe here.
    if (changed && mounted) setState(() {});
  }

  /// #717: focus the terminal ONCE per connect so flterm scroll/interaction is
  /// live immediately — WITHOUT raising the keyboard.
  ///
  /// flterm's `TerminalView` is `autofocus: false`, so on first connect the
  /// terminal isn't focused and flterm's gestures (scroll/select) are inert
  /// until the user taps to raise the keyboard (which is what finally focuses
  /// it). The owner wants vertical scroll to work the moment the session
  /// connects. So on `shellReady` we `controller.requestFocus()` — focus ONLY,
  /// NEVER `showKeyboard()`: #693/#706 deliberately separated focus from raising
  /// the IME, so the keyboard must NOT auto-pop on connect (a later tap still
  /// raises it via the gesture router's onTap).
  ///
  /// Guarded by [ghosttyShouldFocusOnConnect]:
  ///   - ACTIVE-session only: `_SessionTerminalBody` renders every session in an
  ///     `IndexedStack`, so a BACKGROUND session's view is mounted but offstage.
  ///     Focusing it would steal focus from the visible session, so we read
  ///     [activeSessionIdProvider] and bail if this isn't the active session.
  ///   - connected only (a dead PTY has nothing to interact with);
  ///   - once per connect via [_focusedThisConnect] (reset on each shellReady) so
  ///     we don't keep stealing focus on every rebuild.
  void _focusTerminalOnConnect(String trigger) {
    if (!mounted) return;
    final controller = _controller;
    final proxy = _proxy;
    if (controller == null || proxy == null) return;
    final connected = proxy.data.state == SshSessionState.connected;
    final active = ref.read(activeSessionIdProvider) == widget.sessionId;
    if (!ghosttyShouldFocusOnConnect(
      active: active,
      connected: connected,
      alreadyFocused: _focusedThisConnect,
    )) {
      gtrace(
        'ghostty-connect-focus $trigger: skip '
        '(active=$active connected=$connected '
        'alreadyFocused=$_focusedThisConnect)',
      );
      return;
    }
    _focusedThisConnect = true;
    // Focus ONLY — NOT showKeyboard(). The keyboard must NOT auto-pop on connect.
    controller.requestFocus();
    gtrace('ghostty-connect-focus $trigger: focused (no keyboard)');
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
  ///   3. RE-FOCUS (#718): re-fit + scrollToBottom + setState do NOT actually
  ///      repaint flterm — its RenderTerminal repaints on its OWN notifier
  ///      (controller/scroll/focus), scrollToBottom is a no-op at bottom, and a
  ///      widget setState doesn't drive the render box. So the latest snapshot
  ///      stays STALE until the user taps (which focuses flterm). Reusing the
  ///      #717 connect-focus mechanism (reset [_focusedThisConnect], then
  ///      [_focusTerminalOnConnect]) focuses the ACTIVE session's terminal,
  ///      forcing the repaint with NO tap and NO keyboard.
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
    // 3. RE-FOCUS (#718): the #704 re-fit + scrollToBottom + setState above do
    //    NOT repaint flterm — its RenderTerminal repaints on its OWN notifier
    //    (controller/scroll/focus), scrollToBottom is a no-op when already at
    //    bottom, and a widget setState doesn't drive the render box. So on
    //    resume the latest snapshot stays UNPAINTED until the user taps (which
    //    focuses flterm → repaint). #717 already proved focusing fixes the
    //    analogous first-connect case. Reuse it: reset the per-connect focus
    //    latch so the resume re-focuses, then call the SAME active-session-
    //    guarded helper. Focus ONLY (never showKeyboard) — the keyboard must NOT
    //    auto-pop on resume (the #693/#706/#717 focus-vs-IME separation).
    _focusedThisConnect = false;
    _focusTerminalOnConnect('resume');
    // #931 GAP 2: re-assert detection-active on the render box after resume. A
    // background→resume can re-create / re-lay-out the keyed render box, and the
    // init-time one-shot `_applyDetectionActive` does not re-fire — leaving the
    // box `_detectionActive=false` would re-freeze the primary-screen typing half
    // of #931. Re-apply on a post-frame (after the resize-resync re-lays out the
    // grid) reflecting the CURRENT detection settings.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final detection = ref.read(detectionSettingsProvider);
      _applyDetectionActive(
        ghosttyDetectionActiveFor(detection, ref.read(customPatternsProvider)),
      );
    });
    // 4. FORCE REPAINT WHEN FOCUS WAS RETAINED (#720): the #718 re-focus above
    //    only repaints when focus was LOST while backgrounded — the focus CHANGE
    //    fires flterm's `_onFocusChanged` → `notifyListeners()` → the render
    //    box's `_onRenderObserverChanged` → `markNeedsPaint()`. On a device
    //    UNLOCK (or any resume where focus was RETAINED and the grid size didn't
    //    change), `requestFocus()` is a no-op (already focused → no change → no
    //    notify → no repaint), so the view stays STALE until a tap. Force a real
    //    flterm repaint by CYCLING focus — unfocus, then requestFocus on the NEXT
    //    frame so it lands as a genuine focus change (a same-frame toggle would
    //    coalesce to no change). Active-session-guarded (#717/#718) and only when
    //    focus is currently held; never raises the keyboard (the keyboard is down
    //    on resume, so `_onFocusChanged` re-attaches the input but does NOT show).
    _forceRepaintOnResume();
  }

  /// #918: force the flterm render box to re-snapshot + repaint the FULL visible
  /// grid — the SAME full repaint a route-push / Debug-overlay triggers — after
  /// dispatching ANY user input to the PTY (key / tap / gesture / paste / keybar).
  ///
  /// The UI then self-heals on every interaction: if the normal libghostty
  /// damage/frame-sync path dropped a redraw (the "tap Debug fixes it" symptom), the
  /// next input forces it. This is a brute-force SAFETY NET on top of the #900
  /// damage-consume correctness fix — it does NOT replace it.
  ///
  /// The host widget owns only the [TerminalController]; the [TerminalRenderBox] is
  /// an internal leaf of flterm's [TerminalView]. We locate it via the keyed
  /// TerminalView's render object and call [TerminalRenderBox.forceRepaint], which
  /// COALESCES to at most one bounded grid re-read per frame, so dispatching several
  /// inputs in one frame forces only once.
  void _forceTerminalRepaint() {
    final box = _findTerminalRenderBox();
    box?.forceRepaint();
  }

  /// #921: mirror whether structured-text DETECTION is active onto the flterm
  /// render box. When detection is active a SECOND libghostty `RenderState`
  /// handle (the controller's, registered BEFORE the render box) consumes the
  /// shared terminal's per-row damage on the same synchronous notify, starving
  /// the render box's partial build so the PRIMARY screen stops repainting (the
  /// detection-ON paint freeze). Setting [TerminalRenderBox.detectionActive]
  /// makes the primary screen force a full visible-grid re-read on each content
  /// change (the same decoupling the #900 fix uses for the alternate screen), so
  /// the paint is immune to that consume. Reached via the same #918 keyed
  /// render-box lookup; no-ops before first layout (the next registration after
  /// layout re-applies it).
  void _applyDetectionActive(bool active) {
    final box = _findTerminalRenderBox();
    box?.detectionActive = active;
    // #971: record what THIS session's render box was told. detection-off is a
    // confirmed workaround for the no-repaint bug, so a repro must show whether
    // detectionActive was actually set on the STUCK (active) view + that its
    // force-repaint-on-content-change (the #921 remedy) then kept it painting.
    clifecycle(
      'repaint',
      '$_repaintTag detActive=$active box=${box != null}'
      '${_isActiveView ? ' [active]' : ''}',
    );
  }

  /// #918: walk the render subtree under the keyed [TerminalView] to the
  /// [TerminalRenderBox] leaf. Returns null before the first layout (no render
  /// object yet) or if the box can't be found — the caller no-ops.
  TerminalRenderBox? _findTerminalRenderBox() {
    final renderObject = _terminalViewKey.currentContext?.findRenderObject();
    if (renderObject == null) return null;
    final box = _searchRenderBox(renderObject);
    // #922 telemetry: keep the render/sync telemetry seam wired to this session's
    // diagnostic ring on EVERY lookup (the box is re-created when the TerminalView
    // is rebuilt with a new key on theme cycle, so re-asserting here is the same
    // robustness the #931 detectionActive re-assert uses). The render box leaves
    // `onFrameDebug` null in production flterm; binding it to `clifecycle('repaint',
    // …)` lands screen transitions, zero-rebuild content syncs, and settle
    // arm/fire in the captured lifecycle ring the feedback bundle uploads. Idempotent.
    // #971: tag with the session + log ONLY the ACTIVE (visible) view's frames.
    // A busy BACKGROUND session on the alt screen (rebuilt=53 every frame) was
    // drowning the STUCK visible session's telemetry in the shared ring — the
    // conflation that blocked diagnosis. Active-only + tagged makes the visible
    // view's repaint state (incl. the flterm `detActive`/`rebuilt`) legible.
    box?.onFrameDebug = (line) {
      if (!_isActiveView) return;
      logRepaintTelemetry('$_repaintTag $line');
    };
    return box;
  }

  /// Paint replay harness: read the flterm render box's boundary counters for
  /// the [GhosttyPaintStats] snapshot. Looks the box up fresh on every call
  /// (it is re-created on theme-cycle remounts, so a captured reference would
  /// go stale). Empty when unmounted / before first layout — the app-side
  /// bytesIn/writeErrors counters still ship.
  Map<String, Object?> _probePaintBox() {
    if (!mounted) return const <String, Object?>{};
    final box = _findTerminalRenderBox();
    if (box == null) return const <String, Object?>{};
    return <String, Object?>{
      'contentNotifies': box.debugContentNotifyCount,
      'paints': box.debugPaintCount,
      'frameSyncs': box.debugFrameSyncCount,
      'lastSyncRebuiltRows': box.debugRowsRebuiltLastSync,
      'forceRepaints': box.debugForceRepaintCount,
      'detectionActive': box.debugDetectionActive,
    };
  }

  TerminalRenderBox? _searchRenderBox(RenderObject node) {
    if (node is TerminalRenderBox) return node;
    TerminalRenderBox? found;
    node.visitChildren((child) {
      found ??= _searchRenderBox(child);
    });
    return found;
  }

  /// #1072 (telemetry, additive): assemble this session's detection-wash
  /// GEOMETRY snapshot for the bug-report bundle (frozen-bubble diagnosis).
  /// READ-ONLY — reads controller + render-box accessors, mutates nothing.
  /// Null before first layout / when the controller or render box is gone.
  ///
  /// Per anchor (capped) it records the absolute top row, the resolved gutter
  /// row, the row the wash painter WOULD draw on (`absTopRow -
  /// paintedViewportOffset`), and the viewport row where the payload text is
  /// ACTUALLY visible now — so a divergence localizes the freeze to a layer.
  Map<String, Object?>? _probeDetectionGeom() {
    if (!mounted) return null;
    final controller = _controller;
    if (controller == null) return null;
    final box = _findTerminalRenderBox();

    final paintedOffset = controller.paintedViewportOffset;
    final gridRows = controller.scrollbar.visible;

    // Cap the per-anchor detail so a screen full of matches can't bloat the
    // bundle. The COUNT below always reports the full anchor set.
    const maxAnchors = 12;
    final anchors = controller.anchors;
    final anchorGeom = <Map<String, Object?>>[];
    for (final anchor in anchors.take(maxAnchors)) {
      if (anchor.ranges.isEmpty) continue;
      final topRange = anchor.ranges.first;
      final absTopRow = topRange.topRow;
      final payloadStr = anchor.payload.toString();
      final prefix =
          payloadStr.length > 24 ? payloadStr.substring(0, 24) : payloadStr;
      anchorGeom.add(<String, Object?>{
        // Scrubbed defensively — a URL/path payload is not a credential, but the
        // same no-secrets contract as every other bundle string applies.
        'payloadPrefix': scrubSecrets(prefix),
        'patternId': anchor.patternId,
        'absTopRow': absTopRow,
        'gutterRow': controller.anchorGutterRow(topRange),
        'washDrawnViewRow': absTopRow - paintedOffset,
        'payloadActualViewRow':
            _payloadActualViewRow(controller, payloadStr, gridRows),
      });
    }

    return <String, Object?>{
      'activeScreen': controller.activeScreen.name,
      'screenViewportTop': controller.screenViewportTop,
      'scrollbarOffset': controller.scrollbar.offset,
      'paintedViewportOffset': paintedOffset,
      'gridRows': gridRows,
      // The viewport rows the HighlightPainter actually drew the wash on last
      // paint (empty when nothing drew). `null` when the box isn't resolvable.
      'drawnWashViewRows': box?.washViewRows,
      // Monotonic paint counter: compare across two captures to see whether the
      // wash layer repaints AT ALL (a frozen bubble that never advances = the
      // paint was never scheduled). Reuses the existing render-box paint count.
      'paintTick': box?.debugPaintCount,
      'anchorCount': anchors.length,
      'anchors': anchorGeom,
    };
  }

  /// #1072: the viewport row whose visible text currently contains [payloadStr]
  /// (matched on a bounded prefix so a long/wrapped payload still localizes), or
  /// -1 when the payload isn't visible. Scans single rows — the head row of a
  /// wrapped match carries the prefix. Cold path (bug-report time only).
  int _payloadActualViewRow(
    TerminalController controller,
    String payloadStr,
    int gridRows,
  ) {
    if (gridRows <= 0 || payloadStr.isEmpty) return -1;
    final needle =
        payloadStr.length > 16 ? payloadStr.substring(0, 16) : payloadStr;
    for (var r = 0; r < gridRows; r++) {
      final text = controller.visibleRowsText(r, r);
      if (text.contains(needle)) return r;
    }
    return -1;
  }

  /// #720: force flterm to repaint on resume even when focus was RETAINED.
  ///
  /// Gated by [ghosttyShouldCycleFocusForRepaint]: only the ACTIVE, connected
  /// session's view, and only when the terminal currently HAS focus (the
  /// unlock/retained-focus case where `requestFocus()` is a no-op). When focus
  /// was lost, the #718 `_focusTerminalOnConnect('resume')` above already drove a
  /// real focus change → repaint, so this is a no-op and we skip the cycle.
  ///
  /// The cycle is `unfocus()` now + `requestFocus()` on a POST-FRAME callback:
  /// deferring the refocus one frame makes it a genuine focus CHANGE
  /// (focused → unfocused → focused) which fires flterm's `_onFocusChanged` →
  /// `notifyListeners()` → `RenderTerminal._onRenderObserverChanged` →
  /// `markNeedsPaint()`. NEVER `showKeyboard()`: on resume the keyboard is down
  /// (`KeyboardState.hidden`), so the refocus re-attaches the input connection
  /// but does NOT raise the IME — the keyboard stays down.
  void _forceRepaintOnResume() {
    if (!mounted) return;
    final controller = _controller;
    final proxy = _proxy;
    if (controller == null || proxy == null) return;
    final connected = proxy.data.state == SshSessionState.connected;
    final active = ref.read(activeSessionIdProvider) == widget.sessionId;
    final hasFocus = controller.hasFocus;
    if (!ghosttyShouldCycleFocusForRepaint(
      active: active,
      connected: connected,
      hasFocus: hasFocus,
    )) {
      gtrace(
        'ghostty-resume-repaint: skip '
        '(active=$active connected=$connected hasFocus=$hasFocus)',
      );
      return;
    }
    // #931 GAP 1: the focus cycle alone fires `_onRenderObserverChanged` →
    // `markNeedsPaint()` ONLY — it does NOT set `_needsFrameSync` or
    // `markAllRowsDirty()`. On a PRIMARY-screen in-place cursor-addressed redraw
    // with detection ON (the default), a prior detection-driven sync has already
    // CONSUMED libghostty's per-row damage, so the resume `_syncFrameState` runs
    // with NOTHING dirty → the partial build is SKIPPED → the stale buffer
    // repaints (the "switch to apps and back is frozen" half of #931). Pair the
    // focus cycle with a REAL frame-sync (`forceRepaint()` → markAllRowsDirty +
    // frame-dirty, the #918 seam) so resume re-reads the FULL visible grid even
    // when the damage was consumed. Bounded to the visible rows; coalesced to
    // once per frame. The structural cure (a non-consuming detection read) is
    // #922 — this reuses the existing #918 seam.
    _forceTerminalRepaint();
    // Drop focus now; re-request it next frame so the FocusNode actually
    // transitions (focused → unfocused → focused) and flterm repaints. A
    // same-frame toggle would coalesce to no net change and not notify.
    controller.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _controller;
      if (c == null) return;
      // Focus ONLY — never showKeyboard(); the keyboard must stay down on resume.
      c.requestFocus();
      // #931: also re-force a full re-read on the NEXT frame so the post-focus-
      // change frame (which a late detection consume could otherwise starve)
      // re-reads the latest grid too. Coalesces with the focus-driven repaint.
      _forceTerminalRepaint();
      gtrace('ghostty-resume-repaint: focus-cycled + forced (no keyboard)');
    });
  }

  /// #741: keep the keyboard state UNCHANGED across an app-level session-bar
  /// swipe-switch so the bar never jumps down out from under the finger.
  ///
  /// Every session's terminal is mounted in an `IndexedStack`
  /// (terminal_screen.dart), so switching the active session moves the OUTGOING
  /// focused view offstage — its `TextInput` connection detaches and the soft
  /// keyboard collapses — while the INCOMING view is never focused. Each view
  /// listens to [activeSessionIdProvider] and handles its OWN side of the switch:
  ///
  ///   - OUTGOING ([ghosttyShouldCaptureKeyboardOnSessionSwitch]): record whether
  ///     this terminal's keyboard was UP into [sessionSwitchKeyboardWasUpProvider]
  ///     so the incoming view can restore it. The capture must happen BEFORE the
  ///     incoming view's restore reads it; both run synchronously in this same
  ///     provider tick (one notify → every listener), and the incoming view
  ///     defers its keyboard show to a post-frame callback, so ordering holds
  ///     regardless of which view's listener fires first.
  ///   - INCOMING ([ghosttyShouldRestoreFocusOnSessionSwitch]): re-attach focus
  ///     to this newly-active terminal and — iff the keyboard was up
  ///     ([ghosttyShouldShowKeyboardOnSessionSwitch]) — re-show it, so the IME
  ///     stays up (and the bar stays put). When the keyboard was down, focus
  ///     only; it stays down. NEVER unconditionally `showKeyboard()` — the
  ///     #693/#717 focus-vs-IME separation must hold.
  ///
  /// The initial activation (`prev == null`) is left to the #717 connect-focus
  /// path; both gates no-op on it.
  void _onActiveSessionChanged(String? prev, String? next) {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    // #931 GAP 2: re-assert `_detectionActive` on the render box when THIS view
    // becomes the active session. `_applyDetectionActive` is otherwise applied
    // ONCE on a post-frame at init (`_registerUrlPattern`); a view that was
    // OFFSTAGE at init (its keyed render box not yet laid out, so the lookup
    // no-oped) could be left `_detectionActive=false` when it later becomes
    // visible — which drops the primary-screen full re-read and re-freezes the
    // typing/streaming half of #931. Re-apply on the post-frame after this child
    // goes onstage (so the keyed render box exists), reflecting the CURRENT
    // detection settings.
    if (next == widget.sessionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final detection = ref.read(detectionSettingsProvider);
        _applyDetectionActive(
          ghosttyDetectionActiveFor(
            detection,
            ref.read(customPatternsProvider),
          ),
        );
      });
    }
    if (ghosttyShouldCaptureKeyboardOnSessionSwitch(
      sessionId: widget.sessionId,
      prevActiveId: prev,
      nextActiveId: next,
    )) {
      final wasUp = controller.keyboardState == KeyboardState.showing;
      ref.read(sessionSwitchKeyboardWasUpProvider.notifier).state = wasUp;
      gtrace('ghostty-session-switch: captured keyboardWasUp=$wasUp');
    }
    if (ghosttyShouldRestoreFocusOnSessionSwitch(
      sessionId: widget.sessionId,
      prevActiveId: prev,
      nextActiveId: next,
    )) {
      // Re-attach focus synchronously so the IME's input connection follows the
      // newly-active terminal instead of collapsing with the offstage one.
      controller.requestFocus();
      // Read the captured flag and (re-)show the keyboard on a POST-FRAME
      // callback, NOT synchronously: the outgoing view's capture and this
      // restore both run in the SAME provider tick (one notify → every
      // listener), and listener order across the two view instances is
      // unspecified. Reading at post-frame guarantees the capture (synchronous
      // in its own listener) has already written the flag, and that the
      // IndexedStack has put this child onstage so showKeyboard() attaches the
      // IME to it. NEVER show unconditionally — the #693/#717 focus-vs-IME
      // separation: keyboard up before → up after; down before → stays down.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final keyboardWasUp = ref.read(sessionSwitchKeyboardWasUpProvider);
        if (ghosttyShouldShowKeyboardOnSessionSwitch(
          keyboardWasUp: keyboardWasUp,
        )) {
          _controller?.showKeyboard();
        }
        gtrace(
          'ghostty-session-switch: restored focus '
          '(keyboardWasUp=$keyboardWasUp)',
        );
      });
    }
  }

  /// #962: whether [col] (1-based viewport col) falls in the right-edge gutter
  /// strip (~[kGutterSelectStripWidth] px wide), using the live cell width — so
  /// a long-press there can be left to the gutter line-select, not the terminal.
  bool _isGutterCol(int col) {
    final cw = _lastCellSize.width;
    if (cw <= 0 || _cols <= 0) return false;
    final gutterCols = (kGutterSelectStripWidth / cw).ceil();
    return col > _cols - gutterCols;
  }

  /// #705: begin an flterm LOCAL selection at the long-pressed 1-based VIEWPORT
  /// cell. Anchor it (held for the drag) and SET `controller.selection` to a
  /// collapsed span at that cell — mapped to absolute buffer rows by adding the
  /// live scrollback offset, mirroring flterm's own `selectWord`/`selectLine`
  /// (`.scroll(scrollbar.offset)`). Unlike the #692 SGR-tmux path, this PERSISTS
  /// after release so Copy (`selectedText()`) can read it.
  void _onSelectionStart(int col, int row) {
    // #962: body text selection disabled — gutter edge is the sole copy path
    // while clipboard propagation is being fixed. Long-press-drag no longer
    // starts a body selection (swipe still scrolls, tap still focuses).
    if (!kBodyTextSelectionEnabled) return;
    final controller = _controller;
    if (controller == null) return;
    // #962: the right-edge GUTTER owns its own long-press line-select. Suppress
    // the terminal's NATIVE text selection when the gesture starts in the gutter
    // strip, so the two don't both fire (the "two simultaneous selections" bug).
    // A body press (left of the strip) keeps the native selection unchanged.
    if (_isGutterCol(col)) {
      _selStartedInGutter = true;
      return;
    }
    _selStartedInGutter = false;
    _selAnchorCol = col;
    _selAnchorRow = row;
    // #828: a fresh selection invalidates the previous finalised-text snapshot.
    _lastSelectionText = '';
    controller.selection = ghosttySelectionForCells(
      startViewCol: col,
      startViewRow: row,
      endViewCol: col,
      endViewRow: row,
      scrollOffset: controller.scrollbar.offset,
    );
    // #706 (issue 1): record the scrollback length this selection is anchored
    // against, so a later eviction can be detected and the rows shifted.
    _selScrollbackLen =
        controller.scrollbar.total - controller.scrollbar.visible;
  }

  /// #705: extend the in-progress LOCAL selection's END to the dragged 1-based
  /// VIEWPORT cell, keeping the held anchor as the start, so the highlight grows
  /// under the finger. No-op if no anchor is set (no selection in progress).
  void _onSelectionExtend(int col, int row) {
    if (!kBodyTextSelectionEnabled) return;
    final controller = _controller;
    if (controller == null) return;
    // #962: this gesture began in the gutter strip — leave native selection off.
    if (_selStartedInGutter) return;
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
    // #828: snapshot the live selection's text on each extend. The LAST extend
    // before release holds the full drag span, so this captures exactly what the
    // user saw highlighted — kept so Copy honors it even after a #760 tmux redraw
    // clears the live `controller.selection` (see [_copySelection]).
    _lastSelectionText = controller.selectedText();
    // #706: capture the scrollback length the selection was anchored against,
    // so [_reanchorSelectionOnGrowth] can detect later EVICTION and shift the
    // absolute rows to keep the highlight on the same content.
    _selScrollbackLen =
        controller.scrollbar.total - controller.scrollbar.visible;
  }

  /// #706 (issue 2): clear the active flterm LOCAL selection and forget the
  /// content anchor. Invoked when a single tap lands while a selection is
  /// active (the tap is then swallowed). Idempotent.
  ///
  /// #828: [clearSnapshot] controls whether the finalised-text snapshot
  /// ([_lastSelectionText]) is ALSO dropped. A user DISMISS (tap) or a full
  /// scrollback EVICTION (the content is gone) clears it (true, the default); a
  /// #760 tmux-redraw invalidation of the LIVE selection must KEEP it (false) so
  /// Copy can still honor the selection the user visibly made — that's the whole
  /// #828 fix.
  void _clearSelection({bool clearSnapshot = true}) {
    final controller = _controller;
    if (controller == null) return;
    controller.clearSelection();
    _selAnchorCol = null;
    _selAnchorRow = null;
    _selScrollbackLen = null;
    if (clearSnapshot) _lastSelectionText = '';
  }

  /// #706 (issue 1): keep a persisted selection anchored to its CONTENT as
  /// output streams. flterm stores the selection in the absolute, top-anchored
  /// buffer frame and the painter re-reads `scrollbar.offset` each dirty frame,
  /// so while the bounded scrollback is merely FILLING the highlight already
  /// tracks its text (it slides up as new lines arrive). The one case the
  /// absolute frame can't self-correct is scrollback EVICTION: once capped, the
  /// oldest lines drop and every surviving line's index shifts down. We detect
  /// that as a DROP in the scrollback length vs. the value captured when the
  /// selection was made, and shift the rows by the evicted count via
  /// [ghosttyReanchorForEviction] (clamping a partially-evicted span to row 0,
  /// clearing a fully-evicted one).
  ///
  /// LIMIT (documented for the device tester): under tmux MOUSE MODE the remote
  /// runs on the ALTERNATE screen, which has NO scrollback — `scrollbar.offset`
  /// is pinned at 0 and tmux REDRAWS the grid in place rather than scrolling
  /// lines into history. There is then no stable content frame for ANY local
  /// selection (flterm's own selection has the same limit), so a selection made
  /// over alt-screen content cannot track a redraw. This re-anchor covers the
  /// primary-screen streaming case (plain shell / tmux copy-mode scrollback).
  void _reanchorSelectionOnGrowth() {
    final controller = _controller;
    if (controller == null) return;
    final selection = controller.selection;
    final prevLen = _selScrollbackLen;
    if (selection == null || prevLen == null) return;
    final nextLen = controller.scrollbar.total - controller.scrollbar.visible;
    // While the scrollback is still filling (nextLen grows), the absolute frame
    // is stable — flterm tracks it for us, so do nothing. A DROP means eviction:
    // shift the selection up by how many lines were pushed past the cap.
    final evicted = prevLen - nextLen;
    if (evicted <= 0) {
      _selScrollbackLen = nextLen;
      return;
    }
    final reanchored = ghosttyReanchorForEviction(
      selection,
      evictedRows: evicted,
    );
    _selScrollbackLen = nextLen;
    if (reanchored == null) {
      _clearSelection();
      return;
    }
    controller.selection = reanchored;
  }

  /// #760: clear an active selection whose covered content was REDRAWN by remote
  /// output. Runs from [_onControllerChanged] AFTER [_reanchorSelectionOnGrowth]
  /// (so a still-valid primary-screen scrollback selection has already tracked
  /// its eviction) and is gated by [ghosttySelectionInvalidatedByOutput]: it
  /// clears ONLY when a selection is active AND this notify was driven by fresh
  /// remote bytes ([remoteOutput] — set by the output subscription just before
  /// `controller.write`). A pure LOCAL scrollback scroll passes [remoteOutput]
  /// false, so the selection is RETAINED and keeps tracking its content. This is
  /// the #760 fix for the tmux/alt-screen redraw the absolute-row frame can't
  /// self-correct (and the conservative clear-on-next-output for the live
  /// streaming case — selections are short-lived: select → Copy → done).
  void _invalidateSelectionOnRedraw(bool remoteOutput) {
    final controller = _controller;
    if (controller == null) return;
    final invalidate = ghosttySelectionInvalidatedByOutput(
      hasSelection: controller.selection != null,
      remoteOutput: remoteOutput,
    );
    // #828: drop the now-stale LIVE selection (the redrawn rows no longer match
    // the absolute-row span) but KEEP the finalised-text snapshot — under tmux
    // mouse mode the status bar redraws ~1/s, so this fires within a second of a
    // deliberate selection, and the user must still be able to Copy what they
    // visibly selected. [_copySelection] falls back to the snapshot.
    if (invalidate) _clearSelection(clearSnapshot: false);
  }

  // #962: on long-press-drag release, copy the VISIBLE viewport rows the user
  // dragged over — read VERBATIM via PointTag.viewport (controller.visibleRowsText),
  // i.e. exactly what's on screen at those rows. NO selection / scrollback offset
  // / paint-timing machinery (the entire copy-saga debt the owner asked to set
  // aside). Row 0 = top visible row, so the dragged viewport rows map 1:1.
  Future<void> _onGutterCommitRows(int topViewRow, int bottomViewRow) async {
    final controller = _controller;
    if (controller == null) return;
    final text = controller.visibleRowsText(topViewRow, bottomViewRow);
    final firstLine = text.split('\n').firstWhere(
      (l) => l.trim().isNotEmpty,
      orElse: () => '',
    );
    ctrace(
      'gutter-copy',
      'view=[$topViewRow..$bottomViewRow] rows=${controller.scrollbar.visible} '
      'first="${firstLine.length > 40 ? firstLine.substring(0, 40) : firstLine}"',
    );
    if (text.trim().isEmpty) {
      if (mounted) showTopToast(context, 'Nothing to copy on those lines');
      return;
    }
    final rowCount = bottomViewRow - topViewRow + 1;
    // #962 CORPUS CAPTURE: record the FULL rendered gross-select verbatim into
    // the trace so every bug report carries ground-truth fixtures for the
    // smart-copy massager. The rendered layout — TUI forced-whitespace margins,
    // bullets, box-drawing, alignment padding — CANNOT be recovered from the raw
    // byte-trace (pre-render bytes + escapes), so this is the only faithful
    // source. Newlines/backslashes escaped to keep it one trace line; the
    // feedback bundle scrubs secrets before anything leaves the device. The
    // connect-log ring IS the "recent stack" of the last selections.
    final escaped = text.replaceAll(r'\', r'\\').replaceAll('\n', r'\n');
    ctrace('grossselect', 'rows=$rowCount cols=$_cols text="$escaped"');
    final ok = await copyToClipboard(text);
    if (!mounted) return;
    showTopToast(
      context,
      ok ? 'Copied $rowCount line${rowCount == 1 ? '' : 's'}' : 'Copy failed',
    );
  }

  /// Handle a single-TAP that landed on a detected structured match (the tap is
  /// swallowed by the router). #726/#988/#999: a URL/OSC-8 tap COPIES the exact
  /// anchor payload ([ghosttyTapCopyMatch]); a PATH tap NAVIGATES — opens the
  /// SFTP file browser via [_openPath] (owner verdict on #988's tap=copy-for-
  /// both). Copy for paths stays on the long-press menu + gutter mark.
  Future<void> _onMatchTap(StructuredMatch match) async {
    final toast = await ghosttyTapMatchAction(
      match,
      copy: copyToClipboard,
      openPath: _openPath,
      // #1036: relative anchors navigate to their cwd-RESOLVED absolute.
      resolveRelative: _cwdTracker.resolve,
    );
    if (toast != null && mounted) showTopToast(context, toast);
  }

  /// #778 paths Slice 1 / #999: open the SFTP file explorer for [path] (the
  /// tapped / long-press-Open / gutter-Open absolute file path). The explorer
  /// lands at [ghosttyPathBrowseTarget] — the dir itself for a trailing-slash
  /// path, the PARENT dir otherwise (a detected path may name a FILE; without a
  /// stat the parent listing is the useful landing). Absolute paths resolve
  /// without a pwd; relative/pwd resolution is a later slice. Routes through
  /// the single [openFileBrowser] entry point.
  Future<bool> _openPath(String path) async {
    if (!mounted) return false;
    await openFileBrowser(
      context,
      widget.sessionId,
      initialPath: ghosttyPathBrowseTarget(path),
    );
    return true;
  }

  /// #734: show the Copy/Open action menu for a long-pressed URL — the SAME
  /// `showUrlActions` overlay (`url_action_overlay.dart`, keys `url-action-menu`/
  /// `url-action-copy`/`url-action-open`) the xterm path uses, so Copy →
  /// clipboard + toast and Open → `launchUrl` (external). Reuses the detected
  /// [match] ranges (#726) — no duplicate detection.
  ///
  /// Builds the URL's on-screen highlight rects from the match's 0-based viewport
  /// cell range using the SAME geometry the gesture router uses:
  /// [kGhosttyTerminalPadding] + the live [_lastCellSize],
  /// then offset by the view's render-box GLOBAL origin (the overlay layer is
  /// rooted, so it wants global coords). A soft-wrapped URL spans rows → one rect
  /// per row segment, mirroring [ghosttyCellInUrl]'s geometry.
  void _showUrlMenu(StructuredMatch match, Offset globalAnchor) {
    if (!mounted) return;
    final rects = _urlGlobalRects(match);
    // #778: a `path` long-press shows the PATH menu (Open → explorer, Copy path)
    // — the file-path analogue of the URL menu. A url/osc8 match keeps the URL
    // Copy/Open menu. The router suppresses selection for both.
    // #995: every menu shape offers a LAST "Not a URL"/"Not a file" item that
    // persists a detection exception for the ORIGINAL matched payload text.
    void markNot() =>
        _reportDetectionException(match.patternId, '${match.payload}');
    if (match.patternId == kGhosttyPathPatternId) {
      showPathActions(
        context,
        '${match.payload}',
        highlightRects: rects,
        anchor: globalAnchor,
        onOpen: _openPath,
        onMarkNotDetection: markNot,
      );
      return;
    }
    // #1036: a RELATIVE anchor's menu works in RESOLVED-ABSOLUTE semantics —
    // Open navigates to the resolved path, "Copy path" copies the resolved
    // absolute, an extra "Copy relative" copies the matched text verbatim,
    // and the sftp:// form uses the absolute. The exception report keeps the
    // ORIGINAL relative payload (suppression keys on the matched text).
    if (match.patternId == kGhosttyRelPathPatternId) {
      final resolved = _cwdTracker.resolve('${match.payload}');
      showPathActions(
        context,
        resolved,
        relativeText: '${match.payload}',
        highlightRects: rects,
        anchor: globalAnchor,
        onOpen: _openPath,
        sftpUrl: _sftpUrlFor(resolved),
        onMarkNotDetection: markNot,
      );
      return;
    }
    // #994: a file:// url/osc8 anchor is a REMOTE path — it gets the PATH menu
    // (Open → explorer, Copy path) plus the canonical sftp:// form.
    final filePath = ghosttyFileUrlPath(match);
    if (filePath != null) {
      showPathActions(
        context,
        filePath,
        highlightRects: rects,
        anchor: globalAnchor,
        onOpen: _openPath,
        sftpUrl: _sftpUrlFor(filePath),
        onMarkNotDetection: markNot,
      );
      return;
    }
    // #1031 slice 3: a USER-DEFINED match gets the generic menu — Copy + "Not
    // a match" (the IA's v1 tap-action cut: no Open; the payload is an
    // arbitrary token, not a URL).
    if (isCustomPatternId(match.patternId)) {
      showUrlActions(
        context,
        '${match.payload}',
        highlightRects: rects,
        anchor: globalAnchor,
        onMarkNotDetection: markNot,
        showOpen: false,
        notLabel: 'Not a match',
      );
      return;
    }
    showUrlActions(
      context,
      '${match.payload}',
      highlightRects: rects,
      anchor: globalAnchor,
      onMarkNotDetection: markNot,
    );
  }

  /// #994: the canonical `sftp://user@host[:port]/path` form of [path] on THIS
  /// view's session, from the live session entry's identity — or null when the
  /// session is gone (the menu simply omits the sftp action).
  String? _sftpUrlFor(String path) {
    for (final e in ref.read(sessionsProvider).entries) {
      if (e.id == widget.sessionId) {
        return sftpUrlForRemotePath(
          username: e.username,
          host: e.host,
          port: e.port,
          path: path,
        );
      }
    }
    return null;
  }

  /// #995: this view's session host (for the exception record) — from the live
  /// session entry, falling back to the id's host segment when the entry is
  /// gone.
  String _sessionHost() {
    for (final e in ref.read(sessionsProvider).entries) {
      if (e.id == widget.sessionId) return e.host;
    }
    return widget.sessionId.split(':').first;
  }

  /// #995: persist a "Not a URL" / "Not a file" report for ([patternId],
  /// [payload]) and suppress its affordances immediately (the provider watch in
  /// [build] regroups the bubble + gutter layers on the state change).
  ///
  /// The LIVE anchor matching [payload] (when still on screen) supplies the
  /// authoritative patternId (a shared url/osc8 menu passes the family
  /// representative) and the context line via `textForRows` — defensively: a
  /// scrolled-away anchor or an FFI hiccup just records an empty snippet.
  void _reportDetectionException(String patternId, String payload) {
    final controller = _controller;
    var concretePatternId = patternId;
    var contextLine = '';
    if (controller != null) {
      try {
        for (final anchor in controller.anchors) {
          if ('${anchor.payload}' != payload) continue;
          concretePatternId = anchor.patternId;
          if (anchor.ranges.isNotEmpty) {
            final top = anchor.ranges.first.topRow;
            contextLine = controller.textForRows(top, top);
          }
          break;
        }
      } catch (_) {
        // Context is best-effort — the record is still useful without it.
      }
    }
    if (contextLine.length > 200) {
      contextLine = contextLine.substring(0, 200);
    }
    unawaited(
      ref
          .read(detectionExceptionsProvider.notifier)
          .report(
            patternId: concretePatternId,
            matchedText: payload,
            contextLine: contextLine,
            host: _sessionHost(),
          ),
    );
    if (mounted) {
      showTopToast(context, "Won't detect again — undo in Settings");
    }
  }

  /// The GLOBAL on-screen rects for [match]'s cell range (#734/#767). One per
  /// row the match occupies — the [StructuredMatch.ranges] already carry one
  /// per-row [HighlightRange] in ABSOLUTE buffer coords, so we convert each to
  /// VIEWPORT rows via the live scroll offset and lay it out with the SAME
  /// geometry the highlight painter + gesture router use. Empty (the menu still
  /// shows, anchored at the press) if the layout isn't measurable yet.
  List<Rect> _urlGlobalRects(StructuredMatch match) {
    final cell = _lastCellSize;
    if (cell.width <= 0 || cell.height <= 0) return const [];
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return const [];
    final controller = _controller;
    // #863: resolve viewport rows from the PAINTED offset (the offset the bubble
    // decorator / [HighlightPainter] actually drew with), NOT the live
    // `scrollbar.offset` (`_viewportOffsetOf`). The painted offset can trail the
    // live offset by a frame during a tmux-redraw scroll (#803); building these
    // long-press-menu highlight rects from the live offset put the menu's
    // outline a row off the painted bubble + the tappable region. Consuming
    // `controller.paintedViewportOffset` here keeps the menu rects, the painted
    // bubble, and the [matchAt] hit-test all on ONE geometry source.
    final offset = controller == null ? 0 : controller.paintedViewportOffset;
    final origin = box.localToGlobal(Offset.zero);
    final rects = <Rect>[];
    for (final range in match.ranges) {
      final viewRow = range.topRow - offset;
      if (viewRow < 0) continue; // scrolled above the viewport
      final startCol = range.topCol;
      final endCol = range.bottomCol; // exclusive
      if (endCol <= startCol) continue;
      final left = kGhosttyTerminalPadding + startCol * cell.width;
      final top = kGhosttyTerminalPadding + viewRow * cell.height;
      final width = (endCol - startCol) * cell.width;
      rects.add(
        Rect.fromLTWH(origin.dx + left, origin.dy + top, width, cell.height),
      );
    }
    return rects;
  }

  Future<void> _copySelection() async {
    final controller = _controller;
    if (controller == null) return;
    // #828: prefer the LIVE selection's text, but fall back to the finalised-text
    // snapshot when a #760 tmux-redraw cleared the live `controller.selection`
    // out from under a visibly-selected region. Both empty = genuinely nothing
    // selected → then (and only then) the "No selection" hint.
    final text = ghosttyEffectiveCopyText(
      controller.selectedText(),
      _lastSelectionText,
    );
    if (text.isEmpty) {
      if (mounted) {
        showTopToast(
          context,
          'No selection — long-press the terminal, then drag (or tap Select all).',
        );
      }
      return;
    }
    final ok = await copyToClipboard(text);
    if (ok && mounted) showTopToast(context, 'Copied ${text.length} chars');
  }

  /// Select the whole buffer (incl. scrollback) via flterm's native select-all
  /// (#686, fix 3 — best-available selection control: flterm 0.0.3 has no
  /// draggable endpoint handles, so a one-tap "select everything then copy"
  /// path is the most useful extra control we can offer over long-press-drag).
  void _selectAll() {
    final controller = _controller;
    if (controller == null) return;
    controller.selectAll();
    // #706 (issue 1): anchor the content-tracking baseline so a Select-all span
    // is re-offset on eviction too (and a tap dismisses it like any selection).
    _selAnchorCol = null;
    _selAnchorRow = null;
    // #828: snapshot the whole-buffer selection text so Copy survives a #760
    // tmux redraw clearing the live selection, same as the long-press path.
    _lastSelectionText = controller.selectedText();
    _selScrollbackLen =
        controller.scrollbar.total - controller.scrollbar.visible;
    if (mounted) showTopToast(context, 'Selected all — tap copy to grab it.');
  }

  @override
  void dispose() {
    _shellReadySub?.cancel();
    for (final t in _resyncTimers) {
      t.cancel();
    }
    _resyncTimers.clear();
    // #903: drop any pending coalesced resize so a gone widget never resizes,
    // and drop the test-only handle if it's still ours.
    _resizeCoalescer.cancel();
    if (GhosttyTerminalView.debugResizeCoalescers[widget.sessionId] ==
        _resizeCoalescer) {
      GhosttyTerminalView.debugResizeCoalescers.remove(widget.sessionId);
    }
    _outputSub?.cancel();
    // #767 (test-only): drop the debug controller handle if it's still ours.
    if (GhosttyTerminalView.debugControllers[widget.sessionId] == _controller) {
      GhosttyTerminalView.debugControllers.remove(widget.sessionId);
    }
    // #971 (test-only): drop the debug byte-recorder + cell-size handles.
    GhosttyTerminalView.debugByteRecorders.remove(widget.sessionId);
    GhosttyTerminalView.debugCellSizes.remove(widget.sessionId);
    GhosttyTerminalView.debugGrids.remove(widget.sessionId);
    // #990: tear down the path verifier with its session view.
    if (GhosttyTerminalView.debugPathVerifiers[widget.sessionId] ==
        _pathVerifier) {
      GhosttyTerminalView.debugPathVerifiers.remove(widget.sessionId);
    }
    // #1036: drop the cwd tracker's debug seam with its session view.
    if (GhosttyTerminalView.debugCwdTrackers[widget.sessionId] ==
        _cwdTracker) {
      GhosttyTerminalView.debugCwdTrackers.remove(widget.sessionId);
    }
    _controller?.decorationListenable.removeListener(_notePathAnchors);
    _sftpStatSub?.cancel();
    _pathVerifier?.dispose();
    _pathVerifier = null;
    _controller?.removeListener(_onControllerChanged);
    _controller?.onOutput = null;
    // #1072: drop the auto-reply tee with the session.
    _controller?.onTerminalReply = null;
    _controller?.onResize = null;
    _controller?.dispose();
    _scrollController.dispose();
    // #790: this session's terminal is gone — drop its recorder ring (and clear
    // the active pointer if it referenced us, so a stale snapshot can't leak).
    unregisterByteRecorder(widget.sessionId);
    // Paint replay harness: drop the paint-stack counters with the session.
    _paintStats.boxProbe = null;
    unregisterPaintStats(widget.sessionId);
    // #1072: drop the detection-geometry probe with the session.
    unregisterDetectionGeom(widget.sessionId);
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
    // #741: a session-bar swipe-switch must leave the keyboard state UNCHANGED.
    // The IndexedStack moves the outgoing focused view offstage (its TextInput
    // detaches → keyboard collapses) and never focuses the incoming view, so the
    // bar jumps down out from under the finger. Each view listens for the active
    // session changing: the OUTGOING view captures its keyboard-up state; the
    // INCOMING view re-attaches focus and re-shows the keyboard iff it was up.
    ref.listen<String?>(activeSessionIdProvider, (prev, next) {
      _isActiveView = next == widget.sessionId; // #971 telemetry gate
      _onActiveSessionChanged(prev, next);
    });
    // Keybar Reset key: a bumped counter for THIS session runs the local
    // input-mode reset (clears stuck mouse reporting so taps stop echoing SGR
    // codes) — no reconnect, no bytes to the remote.
    ref.listen<Map<String, int>>(inputModeResetProvider, (prev, next) {
      final before = prev?[widget.sessionId] ?? 0;
      final after = next[widget.sessionId] ?? 0;
      if (after != before) _resetInputModes('keybar-reset');
    });
    // #971: current active/visible state for the repaint-telemetry gate. Set on
    // every build (a session switch rebuilds the IndexedStack children).
    _isActiveView = ref.read(activeSessionIdProvider) == widget.sessionId;
    // #888 Part A: LIVE re-apply of the detection toggles. When the global
    // detection settings change, clear the registered patterns (drops anchors +
    // highlights cleanly) and re-run registration against the new settings — so
    // turning URL/path detection off removes existing decorations immediately,
    // and turning it back on re-scans the current cells. No restart needed.
    ref.listen<DetectionSettings>(detectionSettingsProvider, (prev, next) {
      if (prev == next) return;
      final c = _controller;
      if (c == null) return;
      c.clearTextPatterns();
      _registerUrlPattern(c);
      // #968: enabling detection on a LIVE screen (esp. a heavy-repainting tmux/
      // Claude-Code alt screen) can leave the render box starved — the detection
      // RenderState handle consumes the shared per-row damage on the same notify,
      // and the toggle-ON path (unlike init / #931 resume) never re-armed a fresh
      // grid read, so the screen froze on-device ("can't scroll / not repainting
      // / didn't detect but failed to paint"). Force ONE coalesced full re-read
      // after re-registration. Post-frame so the keyed render box exists +
      // `_applyDetectionActive` (scheduled in _registerUrlPattern) has landed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _forceTerminalRepaint();
      });
    });
    // #1031 slice 2: a lab COMMAND-LEXICON change must re-register (the
    // lexicon is baked into the registered TextPattern's normalize closure).
    // Compared by CONTENT — color/intensity changes repaint via the resolver
    // watch below and must NOT churn the pattern registrations.
    ref.listen<DetectionStyles>(detectionStylesProvider, (prev, next) {
      final before = prev?.of(kGhosttyCommandPatternId)?.lexicon;
      final after = next.of(kGhosttyCommandPatternId)?.lexicon;
      if (listEquals(before, after)) return;
      final c = _controller;
      if (c == null) return;
      c.clearTextPatterns();
      _registerUrlPattern(c);
      // Same starvation guard as the settings listen above (#968).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _forceTerminalRepaint();
      });
    });
    // #1031 slice 3: a USER-DEFINED pattern change (create / edit / enable /
    // delete) re-registers, exactly like the settings + lexicon listens above
    // — the regex is baked into the registered TextPattern, so a live change
    // must clear + re-register (and re-scan the current cells).
    ref.listen<List<CustomPattern>>(customPatternsProvider, (prev, next) {
      if (listEquals(prev, next)) return;
      final c = _controller;
      if (c == null) return;
      c.clearTextPatterns();
      _registerUrlPattern(c);
      // Same starvation guard as the settings listen above (#968).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _forceTerminalRepaint();
      });
    });
    // #995: watch the detection-exceptions list so a "Not a URL"/"Not a file"
    // report (or a Settings remove) rebuilds this view — the bubble + gutter
    // layers regroup through the [_isPayloadVisible] gate and the affordances
    // disappear/return immediately. The hot per-anchor lookup itself reads the
    // notifier's hash-set index, not this state.
    ref.watch(detectionExceptionsProvider);
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
    // #716: per-session THEME palette, read from the SAME provider the xterm
    // body reads (terminal_screen.dart `sessionTerminalThemeProvider`). Watching
    // it here means cycling the session's theme rebuilds the TerminalView with a
    // new flterm Terminaltheme — previously buildGhosttyTheme ignored the
    // palette so only the session-menu LABEL changed, never flterm's colors.
    final palette = ref.watch(sessionTerminalThemeProvider(widget.sessionId));
    // #699: measure the REAL flterm cell size from the SAME font + DPR flterm
    // renders with, so the gesture router's touch->cell map divides by the cell
    // height flterm actually laid out (not overlayHeight/rows — the #699 bug).
    final theme = buildGhosttyTheme(
      family: fontFamily,
      fontSize: fontSize,
      palette: palette.theme,
    );
    final devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    // #1085: detect a windowing transition (desktop-mode entry, rotation,
    // freeform resize). Reading MediaQuery.sizeOf here makes this build depend on
    // the window size, so it re-runs on a real resize (a soft keyboard changes
    // viewInsets, not size, so it never trips this). On the transition, arm the
    // auto-reply settle (post-frame — don't mutate controller state mid-build) so
    // the terminal's re-probed DA/DSR/mouse replies don't leak as `?62c` at the
    // prompt. Complements the #1072 shellReady/reconnect arm, which config-change
    // transitions bypass (no shellReady fires).
    final windowSize = MediaQuery.sizeOf(context);
    if (ghosttyWindowChangedMaterially(_lastWindowSize, windowSize)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller?.beginReconnectSettle();
      });
    }
    _lastWindowSize = windowSize;
    final cellSize = ghosttyMeasureCellSize(
      fontSize: theme.fontSize,
      fontFamily: theme.fontFamily,
      fontWeight: theme.fontWeight,
      fontFamilyFallback: theme.fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
    );
    // #734: remember the live cell size so a long-press URL menu can build its
    // highlight rects with the same geometry the router maps touches with.
    _lastCellSize = cellSize;
    // #971 (test-only): publish the measured cell size so the gesture test can
    // convert a status-bar label column to the exact tap pixel.
    GhosttyTerminalView.debugCellSizes[widget.sessionId] = cellSize;
    // #755/#767/#955/#988/#1074: URLs + paths are DETECTED + ANCHORED inside
    // the terminal (the `url`/`path` structured-text patterns over its own
    // cells). The VISUALS are the LIVE wash LAYER ([GhosttyWashLayer], capsule
    // fills UNDER the transparent terminal) and the right-edge GUTTER mark
    // ([GhosttyGutterLayer]), both coloured with the live session selection
    // colour — no host re-detect. The colourless pattern registration never
    // needs re-registering on a theme change; cycling the session theme rebuilds
    // this view, which recolours both widget layers on the next build.
    final highlightColor = palette.theme.selection;
    if (highlightColor != _lastHighlightColor) {
      _lastHighlightColor = highlightColor;
    }
    // #1000: the bubble WASH tunes its alpha per the TERMINAL background's
    // luminance (a dark theme needs less pigment than a light one), so derive
    // the brightness from the live session palette alongside the accent.
    final backgroundBrightness =
        ThemeData.estimateBrightnessForColor(palette.theme.background);
    // #1031: the detection style RESOLVER — the single source of truth the
    // wash layer + gutter chip consult (and the Detection Lab preview reads).
    // Watching the styles provider means we resolve on CHANGE only
    // (settings/theme), never per frame; an empty store composes to exactly
    // the shipped #1000 derivation, so this is invisible until the owner
    // tunes something in the lab. #1074: the wash is a widget layer built from
    // this resolver, so a style-input change (lab live-apply, theme cycle, #995
    // exception — all of which rebuild this view via the provider watches)
    // recolours it by rebuilding the layer; no fork re-bake / post-frame needed.
    final styleResolver = DetectionStyleResolver(
      styles: ref.watch(detectionStylesProvider),
      accent: highlightColor,
      backgroundBrightness: backgroundBrightness,
    );
    // #922: wrap in a LayoutBuilder so we read the terminal box's ACTUAL
    // constraints — the height the Scaffold has ALREADY shrunk for the soft
    // keyboard (terminal_screen.dart keeps `resizeToAvoidBottomInset:true`, so
    // the body — and this box — is the keyboard-reduced VISIBLE height). We then
    // compute the keyboard-aware grid ourselves and submit it to the resize
    // coalescer, so the FINAL settled size tracks the visible viewport rather
    // than flterm's onResize (which the device capture proved settles back to the
    // pre-keyboard tall size under the keyboard animation race). Submitted on a
    // post-frame (the box size is known post-layout; submitting during layout is
    // illegal), and the coalescer's #903 debounce + no-op guard keep it bounded.
    return LayoutBuilder(
      builder: (context, constraints) {
        _submitKeyboardAwareGrid(constraints.biggest, cellSize);
        return _buildTerminalStack(
          controller: controller,
          theme: theme,
          cellSize: cellSize,
          highlightColor: highlightColor,
          styleResolver: styleResolver,
        );
      },
    );
  }

  /// #922: compute the keyboard-aware grid from the laid-out [box] (already
  /// keyboard-reduced by the Scaffold) + the REAL [cellSize], and submit it to
  /// the resize coalescer. This is the AUTHORITATIVE size driver — it keeps
  /// tmux's grid (and the #719 last-sent rows the status-tap targets) matched to
  /// the VISIBLE viewport, immune to the keyboard-animation race that left
  /// flterm's onResize settling back on the tall pre-keyboard size.
  ///
  /// Runs on a post-frame (reading the box during layout is fine, but submitting
  /// — which may schedule a Timer + later setState via the coalescer's send seam
  /// — is deferred so it never re-enters build). Skips a degenerate box (a
  /// pre-layout 0×0 frame) and a no-change grid (the coalescer would no-op
  /// anyway, but this avoids re-arming the debounce on every unrelated rebuild).
  void _submitKeyboardAwareGrid(Size box, Size cellSize) {
    if (box.width <= 0 || box.height <= 0) return;
    final (cols, rows) = ghosttyGridForBox(
      boxWidth: box.width,
      boxHeight: box.height,
      cellWidth: cellSize.width,
      cellHeight: cellSize.height,
    );
    if (cols == _lastSubmittedGridCols && rows == _lastSubmittedGridRows) {
      return;
    }
    _lastSubmittedGridCols = cols;
    _lastSubmittedGridRows = rows;
    // #975: mirror the keyboard-aware grid into _cols/_rows NOW (synchronous
    // plain-field writes during layout are legal — no setState). This is the
    // SOLE writer of the mirror since flterm's onResize no longer clobbers it, so
    // the gesture router / gutter-select layer read the visible-viewport grid on
    // THIS frame instead of lagging a frame behind (they used to get flterm's
    // synchronous onResize write). The coalesced PTY SEND stays deferred to a
    // post-frame (it may schedule a Timer + later setState via the send seam).
    _cols = cols;
    _rows = rows;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _byteRecorder.recordGrid(cols, rows);
      _resizeCoalescer.submit(cols, rows);
      gtrace('ghostty-kbgrid: cols=$cols rows=$rows box=${box.height.round()}');
    });
  }

  Widget _buildTerminalStack({
    required TerminalController controller,
    required TerminalTheme theme,
    required Size cellSize,
    required Color highlightColor,
    required DetectionStyleResolver styleResolver,
  }) {
    // #975 (test-only): publish the grid the router will map gestures with this
    // frame so the keyboard-race repro can see the SGR target vs the visible box.
    GhosttyTerminalView.debugGrids[widget.sessionId] =
        <int>[_cols, _rows, _lastSentCols, _lastSentRows];
    // #1074: one anchor's wash FILL colour (null → paints nothing). Composes the
    // SAME gates the retired #1045 render-box resolver did — pattern routing +
    // the #990/#995/#1036 visibility suppression — over the live #1031 style
    // resolver captured this build. Read via `ref.read` inside the layer's
    // ListenableBuilder rebuilds (safe: never establishes a dependency).
    Color? washColorFor(StructuredAnchor anchor) {
      final patternId = anchor.patternId;
      final payload = '${anchor.payload}';
      return ghosttyWashCapsuleColor(
        patternId: patternId,
        visible: _isPayloadVisible(patternId, payload),
        verified: _isPayloadVerified(patternId, payload),
        washColorOf: (id, {required bool verified}) =>
            styleResolver.resolveStyle(id, verified: verified).washColor,
      );
    }

    return Stack(
      key: Key('ghostty-terminal-${widget.sessionId}'),
      children: [
        // #1074: SOLID BACKDROP — the opaque terminal background the transparent
        // terminal (backgroundOpacity 0) composites over. Bottom of the stack.
        Positioned.fill(
          child: ColoredBox(color: theme.background),
        ),
        // #1074: the LIVE wash LAYER, UNDER the terminal. Capsule fills resolved
        // from the controller's CURRENT anchors every build (decoration listenable
        // + the path verifier for the #990 verified shade). Default-bg cells above
        // are transparent so the wash shows through BEHIND the glyphs; explicit-bg
        // cells + glyphs stay opaque and occlude it. This is the root fix for the
        // #1045 frozen band: the wash tracks live like the gutter, not only when
        // the render box repaints.
        Positioned.fill(
          child: GhosttyWashLayer(
            controller: controller,
            washColorFor: washColorFor,
            repaintListenable: _pathVerifier,
          ),
        ),
        Positioned.fill(
          child: TerminalView(
            // #918: keyed so _forceTerminalRepaint can locate the render box.
            key: _terminalViewKey,
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
          child: GhosttyPointerGestureRouter(
            active: ghosttySwipeShouldScrollLocally(
              mouseTracking: _mouseTracking,
            ),
            scrollController: _scrollController,
            cols: _cols,
            rows: _rows,
            // #719: target the window-switch wheel at tmux's REAL status row
            // (the last grid we told it), not the possibly-diverged live grid.
            lastSentCols: _lastSentCols,
            lastSentRows: _lastSentRows,
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
              // #918: a tap is user input — force the full repaint so the view
              // self-heals on tap (the same gesture the Debug overlay used to need).
              _forceTerminalRepaint();
            },
            // Long-press-start focuses without raising the keyboard (selection).
            onFocus: controller.requestFocus,
            onMouseReport: (report) {
              final proxy = _resolveProxy();
              if (proxy == null) return;
              if (proxy.data.state != SshSessionState.connected) return;
              final bytes = Uint8List.fromList(report.codeUnits);
              // #793: capture the synthesized window-switch wheel / tap-click /
              // selection SGR report the app sends (the recorder filters to
              // SGR-mouse bytes — never keystrokes).
              _byteRecorder.recordSentSgr(bytes);
              proxy.sendInput(bytes);
              // #918: a synthesised mouse report (tap-click / wheel / selection
              // drag) is user input — force the full repaint.
              _forceTerminalRepaint();
            },
            // #911 Part C: under the control-mode flag, window switching uses REAL
            // tmux commands over the -CC channel (no synthesised SGR at a guessed
            // status row). Flag OFF leaves the SGR path above unchanged.
            controlModeGestures: tmuxControlMode,
            onWindowSwitch: ({required bool next}) {
              final proxy = _resolveProxy();
              if (proxy == null) return;
              if (proxy.data.state != SshSessionState.connected) return;
              proxy.sendTmuxGesture(
                next
                    ? TmuxWindowGesture.nextWindow
                    : TmuxWindowGesture.previousWindow,
              );
              // #918: a window-switch swipe is user input — force the full repaint
              // so the switched window's grid re-reads on EVERY swipe (the historic
              // "works/fails/works" alternation the Debug tap masked).
              _forceTerminalRepaint();
            },
            onStatusTap: ({required int col, required int totalCols}) {
              final proxy = _resolveProxy();
              if (proxy == null) return;
              if (proxy.data.state != SshSessionState.connected) return;
              proxy.sendTmuxGesture(
                TmuxWindowGesture.tapStatusCol,
                statusCol: col,
                statusCols: totalCols,
              );
              // #918: a status-row tap (tmux window select) is user input.
              _forceTerminalRepaint();
            },
            // #906 Stage 2: a vertical swipe scrolls the tmux scrollback via a
            // real capture-pane history request (control mode emits no %output
            // for copy-mode scroll, so the local scrollback can't show it). GATED
            // OFF (kControlModeScrollRenders): the capture request→response byte
            // path is proven, but flterm's grid does not yet DISPLAY a captured
            // history WINDOW (its own scrollback + follow-to-bottom bury it — a
            // flterm-internal render change is pending). Until then, wiring this
            // would FREEZE the screen on a swipe (worse than the harmless local
            // no-op), so a vertical swipe stays on the local [_applyScroll] path.
            // Flip the flag to `true` once flterm renders the scrolled capture.
            onScroll: kControlModeScrollRenders
                ? (deltaLines) {
                    final proxy = _resolveProxy();
                    if (proxy == null) return;
                    if (proxy.data.state != SshSessionState.connected) return;
                    proxy.sendTmuxScroll(deltaLines);
                    _forceTerminalRepaint();
                  }
                : null,
            // #705: long-press-drag drives flterm's LOCAL selection (persists
            // after release → Copy reads it), not a tmux SGR drag.
            onSelectionStart: _onSelectionStart,
            onSelectionExtend: _onSelectionExtend,
            // #706 (issue 2): a single tap dismisses an active selection and is
            // swallowed. The parent owns the controller, so it answers "is a
            // selection active?" live and clears it on demand.
            // #828: a surviving finalised-text snapshot also counts as "selected"
            // (the live selection may have been cleared by a #760 tmux redraw),
            // so a tap still dismisses the visibly-selected region.
            hasSelection: () => ghosttyHasCopyableSelection(
              liveSelection: controller.selection != null,
              snapshot: _lastSelectionText,
            ),
            onSelectionClear: _clearSelection,
            // #726/#767: resolve a tapped cell (0-based viewport) to a detected
            // structured match. Detection lives INSIDE the terminal now, so we
            // ask the controller directly — no app-side URL list. #990: a
            // SUPPRESSED match (unverified single-segment path) shows NO
            // affordance — including tap actions — so it doesn't hit-test.
            urlAtCell: (col, row) {
              // #998 C: glass taps hit-test SPAN-tier matches only. The
              // BLOCK-tier command anchor's affordance is the gutter chip —
              // a tap on command text that is not an inner URL/path must keep
              // its pre-#998 behavior (selection etc.), never block tap-copy.
              final match = controller.matchAt(
                row: row,
                col: col,
                tier: TextTier.span,
              );
              if (match == null) return null;
              if (!_isPayloadVisible(match.patternId, '${match.payload}')) {
                return null;
              }
              return match;
            },
            // #999: URL/OSC-8 taps copy; PATH taps navigate (file browser).
            onUrlTap: _onMatchTap,
            // #734: a long-press on a detected URL shows the Copy/Open action
            // menu (the same `showUrlActions` overlay the xterm path uses). The
            // parent builds the on-screen highlight rects + anchor from the match
            // and hands them to the overlay.
            onUrlLongPress: _showUrlMenu,
          ),
        ),
        // #1074: the detection wash is the LIVE [GhosttyWashLayer] mounted at
        // the BOTTOM of this stack (under the transparent terminal), not here and
        // not in the fork's paint pass. Taps route through the gesture router's
        // `matchAt` (the fill was never the hit-test). The gutter marks below
        // coexist unchanged.
        // #962: right-edge LINE-SELECT layer. Drag the gutter to select WHOLE
        // viewport rows; on release the rows' text is copied (auto-copy). This
        // replaces per-character touch selection as the primary copy path — line
        // granularity removes the sub-cell precision that drove the selection
        // drift saga (#705/#706/#760/#828/#930/#962). Mounted ABOVE the router
        // (claims vertical drags in the right strip) but BELOW the detection
        // marks (so a tap on a mark still fires its action). Converts the
        // reported VIEWPORT rows to absolute rows with the PAINTED offset — the
        // same source the painted text used — so what you drag is what you copy.
        Positioned.fill(
          child: GutterLineSelectLayer(
            cellHeight: cellSize.height,
            rows: _rows,
            color: highlightColor,
            padding: kGhosttyTerminalPadding,
            onCommitRows: _onGutterCommitRows,
          ),
        ),
        // #955: the right-edge GUTTER layer (replaces the inline decorator). The
        // terminal OWNS URL/path detection + persistent cell-sequence ANCHORING;
        // this layer reads `controller.anchors`, resolves each to a VIEWPORT row
        // via `controller.anchorGutterRow` (painted-offset, in lockstep with the
        // painted rows — #955), GROUPS them by row, and renders ONE small
        // monochrome mark per matched row at the right edge. No glyph-cell
        // geometry → no scroll drift (the #930/#803/#812/#863/#864 inline-bubble
        // saga). #993: TRACKS mid-scroll (rows re-resolve on every painted-
        // offset notify; taps ignored while scrolling). Mounted
        // ABOVE the gesture router so a tap on a mark is consumed by the mark
        // (everywhere else is transparent and falls through to the router below).
        Positioned.fill(
          child: GhosttyGutterLayer(
            controller: controller,
            registry: _gutterRegistry,
            color: highlightColor,
            cellHeight: cellSize.height,
            padding: kGhosttyTerminalPadding,
            // #990: a row with a verified path anchor renders the bold chip;
            // unverified SINGLE-SEGMENT matches get no mark (and drop out of
            // multi-match counts).
            isVerified: _isAnchorVerified,
            isVisible: _isAnchorVisible,
            verificationListenable: _pathVerifier,
            // #1031: per-pattern chip accent via the style resolver (the chip
            // stays opaque; only a colorHex override changes its hue).
            chipAccentOf: (patternId) => styleResolver
                .resolveStyle(patternId, verified: false)
                .chipAccent,
          ),
        ),
        // Selection affordances (bottom-right). #712: shown ONLY while a
        // selection is active ([_hasSelection], driven by _onControllerChanged)
        // — a clean terminal otherwise. A deliberate long-press-drag drives a
        // remote (tmux) native selection via SGR reports (#692); Select-all +
        // Copy operate on flterm's LOCAL selection (Select-all, double/triple-
        // tap) — copying a tmux-native span is tmux's own copy mode. #712 also
        // swaps the order: COPY on top, SELECT-ALL below. A future smart-select
        // button would select a word/path/URL unit at the tap (PWA selection.ts
        // _selectableUnitAt) — see file header.
        if (kBodyTextSelectionEnabled &&
            ghosttyShouldShowAffordances(hasSelection: _hasSelection))
          Positioned(
            right: 4,
            bottom: 4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                const SizedBox(height: 8),
                // #692: select-all (flterm-local). The #688 select-mode toggle
                // is gone — a deliberate long-press-drag now selects
                // automatically.
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
              ],
            ),
          ),
      ],
    );
  }
}
