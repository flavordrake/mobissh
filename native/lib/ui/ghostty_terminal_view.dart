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

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// The PER-SESSION theme palettes (#552/#571) are xterm.dart `TerminalTheme`s
// (see [terminalPalettes] / [NamedTerminalTheme] in ui_prefs_providers.dart).
// Both xterm AND flterm export a type named `TerminalTheme`, so the xterm one
// is imported with a prefix to avoid colliding with flterm's (the type this
// view feeds the flterm `TerminalView`). [buildGhosttyTheme] maps from one to
// the other (#716).
import 'package:xterm/xterm.dart' as xterm;

import '../diagnostics/gesture_trace.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../state/ctrl_modifier_provider.dart';
import '../state/lifecycle_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import 'ghostty_url_detector.dart';
import 'keybar.dart';
import 'top_toast.dart';
import 'url_action_overlay.dart';

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
TerminalTheme buildGhosttyTheme({
  required String family,
  required double fontSize,
  xterm.TerminalTheme? palette,
}) {
  final base = TerminalTheme.dark();
  if (palette == null) {
    return base.copyWith(fontFamily: family, fontSize: fontSize);
  }
  return base.copyWith(
    fontFamily: family,
    fontSize: fontSize,
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

/// Whether a LONG-PRESS should show the URL Copy/Open action menu instead of
/// starting a selection (#734).
///
/// #726 wired single-tap-to-copy on the ghostty (default) terminal, but the
/// long-press → Copy/Open menu (`showUrlActions` / url_action_overlay.dart) was
/// only wired into the xterm branch. #734 wires it into the ghostty long-press:
/// on a long-press the router hit-tests the press cell against the SAME detected
/// URL ranges tap-copy uses ([ghosttyUrlAtCell] over the parent's `_urlMatches`).
/// If a URL is at the cell ([urlAtCell] non-null) the router shows the action menu
/// and SUPPRESSES the #705/#706 selection for that gesture; otherwise the existing
/// long-press selection starts unchanged. So the URL hit-test WINS over selection.
///
/// This trivial predicate factors the decision out of the widget so it's
/// unit-testable headless (and names the rule at the call site). Pure.
bool ghosttyLongPressShowsUrlMenu(GhosttyUrlMatch? urlAtCell) =>
    urlAtCell != null;

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
  });

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

  /// #726: resolve a 0-based viewport ([col], [row]) cell to the URL it lands
  /// in, or null. The parent owns the detected [GhosttyUrlMatch] list, so it
  /// answers this live at tap time via [ghosttyUrlAtCell].
  final GhosttyUrlMatch? Function(int col, int row) urlAtCell;

  /// #726: copy the tapped URL (a single-tap on a highlighted URL copies it +
  /// shows a top-toast). When a tap lands on a URL the gesture is SWALLOWED —
  /// no #693 SGR click / focus / type is forwarded — exactly like the #706
  /// selection-dismiss path.
  final void Function(GhosttyUrlMatch match) onUrlTap;

  /// #734: a LONG-PRESS that lands on a detected URL shows the Copy/Open action
  /// menu (`showUrlActions`) instead of starting a selection. The parent builds
  /// the highlight rects + anchor and calls `showUrlActions`; [match] is the URL
  /// at the pressed cell and [globalAnchor] is the long-press global position the
  /// menu anchors near. When this fires the selection gesture is SUPPRESSED for
  /// the rest of the long-press (no `onSelectionStart`/`onSelectionExtend`), so
  /// the URL hit-test WINS over the #705/#706 selection. Off any URL this never
  /// fires and selection starts as today.
  final void Function(GhosttyUrlMatch match, Offset globalAnchor)
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

  void _onPanStart(DragStartDetails details) {
    _panDx = 0;
    _panDy = 0;
    _axis = GhosttySwipeAxis.none;
    _windowSwitchDx = 0;
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
      } else {
        _applyScroll(_panDy);
      }
      return;
    }
    // Committed: run ONLY the locked axis; the off-axis component is ignored.
    if (_axis == GhosttySwipeAxis.horizontal) {
      _windowSwitchDx += dx; // accumulate for the on-lift window-switch
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
      _trace('longpress-url', local.dx, local.dy, col, row, 'menu');
      widget.onUrlLongPress(url!, details.globalPosition);
      return;
    }
    _longPressOnUrl = false;
    // #705: drive flterm's LOCAL selection (NOT a tmux SGR drag, which tmux's
    // default copy-and-cancel would clear on release). Anchor a collapsed
    // selection at the pressed cell; the parent adds the scroll offset.
    _trace('longpress-select', local.dx, local.dy, col, row, 'start');
    widget.onSelectionStart(col, row);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    // #734: while the URL menu owns this long-press, a drag must NOT extend a
    // selection (the gesture belongs to the menu).
    if (_longPressOnUrl) return;
    final local = details.localPosition;
    final (col, row) = _cellAt(local);
    // #705: extend the LOCAL selection's END to the dragged cell so the
    // highlight grows under the finger.
    _trace('longpress-select', local.dx, local.dy, col, row, 'extend');
    widget.onSelectionExtend(col, row);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    // #734: a URL-menu long-press has no selection to finalise.
    if (_longPressOnUrl) {
      _longPressOnUrl = false;
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

/// Paints the URL HIGHLIGHT overlay above the flterm [TerminalView] (#726).
///
/// flterm 0.0.3 has exactly ONE selection and no multi-range highlight API, so
/// detected URLs can't be marked via the controller. Instead this CustomPainter
/// draws a subtle UNDERLINE under each URL's cell range, using the SAME
/// #723-correct cell metrics ([cellWidth]/[cellHeight]) and the
/// [kGhosttyTerminalPadding] the grid is offset by — so the underline lands
/// exactly under the on-screen text. It repaints when the [matches] list, the
/// cell metrics, or the [color] change (the parent re-runs detection on a
/// debounced controller notify + on scroll, and rebuilds this painter), so the
/// highlights follow scroll + resize.
///
/// Each [GhosttyUrlMatch] is in 0-based VIEWPORT cells ([endCol] exclusive). A
/// single-row URL underlines `[startCol, endCol)` on its row; a soft-wrapped URL
/// underlines the start row's tail, every interior row full-width, and the end
/// row's head — matching [ghosttyCellInUrl]'s hit-test geometry so what's
/// underlined is exactly what a tap copies. Pure paint (no FFI) — the geometry
/// is exercised by the matcher tests via the shared cell model.
class GhosttyUrlHighlightPainter extends CustomPainter {
  GhosttyUrlHighlightPainter({
    required this.matches,
    required this.cellWidth,
    required this.cellHeight,
    required this.cols,
    required this.color,
    this.padding = kGhosttyTerminalPadding,
  });

  /// The detected URL ranges to underline (0-based viewport cells).
  final List<GhosttyUrlMatch> matches;

  /// The REAL flterm cell size (see [ghosttyMeasureCellSize]) — the underline
  /// geometry MUST use this, not `size/rows`, to land under the rendered text.
  final double cellWidth;
  final double cellHeight;

  /// The grid width, used to extend an interior/start row's underline to the
  /// full row when a URL wraps.
  final int cols;

  /// The underline colour (the theme's accent / selection colour) so the
  /// highlight is theme-consistent (#716).
  final Color color;

  /// The flterm [TerminalView] padding the grid is offset by ([kGhosttyTerminalPadding]).
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    if (cellWidth <= 0 || cellHeight <= 0 || matches.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final m in matches) {
      for (var row = m.startRow; row <= m.endRow; row++) {
        final startCol = row == m.startRow ? m.startCol : 0;
        final endCol = row == m.endRow ? m.endCol : cols;
        if (endCol <= startCol) continue;
        final x0 = padding + startCol * cellWidth;
        final x1 = padding + endCol * cellWidth;
        // Underline sits ~1px above the cell's bottom edge.
        final y = padding + (row + 1) * cellHeight - 1.5;
        canvas.drawLine(Offset(x0, y), Offset(x1, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(GhosttyUrlHighlightPainter old) =>
      old.color != color ||
      old.cellWidth != cellWidth ||
      old.cellHeight != cellHeight ||
      old.cols != cols ||
      old.padding != padding ||
      !_sameMatches(old.matches, matches);

  static bool _sameMatches(List<GhosttyUrlMatch> a, List<GhosttyUrlMatch> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  /// #734: the REAL flterm cell size last measured in [build] (via
  /// [ghosttyMeasureCellSize]), captured so [_showUrlMenu] can build the URL's
  /// on-screen highlight rects with the SAME geometry the router + highlight
  /// painter use — without re-reading the per-session font providers off-build.
  Size _lastCellSize = Size.zero;

  /// #705: the long-press selection ANCHOR — the 1-based VIEWPORT cell of the
  /// long-press-start, held while the finger drags so each extend rebuilds the
  /// flterm `TerminalSelection` with this fixed start and the moving end. Null
  /// when no selection gesture is in progress.
  int? _selAnchorCol;
  int? _selAnchorRow;

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

  /// #726: the URLs currently detected in the VISIBLE viewport, highlighted by
  /// [GhosttyUrlHighlightPainter] and hit-tested by a tap (single-tap copies the
  /// URL). Re-detected on a DEBOUNCED controller notify (output/scroll) via
  /// [_scheduleUrlDetect] so streaming output doesn't re-scan every byte.
  List<GhosttyUrlMatch> _urlMatches = const [];

  /// #726: debounce timer for URL re-detection. The controller notifies on every
  /// output write; coalesce a burst into a single scan after a short idle.
  Timer? _urlDebounce;

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

  /// #717: whether THIS connect has already focused the terminal. flterm's
  /// `TerminalView` is `autofocus: false`, so on first connect the terminal is
  /// unfocused and flterm scroll/interaction is inert until a tap raises the
  /// keyboard (which focuses it). We `requestFocus()` ONCE per connect (focus
  /// only, NOT showKeyboard — the IME must not auto-pop) when this is the active
  /// session's view, gated by [ghosttyShouldFocusOnConnect]. Set true after the
  /// focus fires; reset false on disconnect so a reconnect re-focuses.
  bool _focusedThisConnect = false;

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
        proxy.sendInput(_applyArmedCtrlToKeystroke(bytes));
      };
      // Grid resize -> PTY resize. flterm reports (cols, rows); the proxy's
      // pixel sizes default to 0 (the task isolate only needs cols/rows). Also
      // mirror (cols, rows) so the #692 gesture router can map touch -> cell.
      controller.onResize = (cols, rows) {
        // Mirror the live grid (for the touch->cell map) AND send the resize
        // through the single [_sendResize] helper so the rows tmux is told about
        // can never diverge from what the window-switch wheel targets (#719).
        _cols = cols;
        _rows = rows;
        _sendResize(cols, rows);
        // #726: a resize changes the cell ranges (and the cols the matcher joins
        // wrapped rows by), so re-detect URLs against the new grid (debounced).
        _scheduleUrlDetect();
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
      controller.addListener(_onControllerChanged);
      _mouseTracking = controller.mouseTracking;
      _controller = controller;
      // #702: arm the first-connect resize re-sync on the proxy's shellReady
      // stream. The xterm #666 fit-burst is offstage for ghostty, so this is the
      // ghostty-LOCAL equivalent: once the task-side shell EXISTS, force-re-send
      // the current grid so the size that reaches tmux is the post-layout one,
      // not the pre-shellReady default that gets dropped. Re-fires on reconnect.
      _shellReadySub = proxy.shellReady.listen((_) {
        if (!mounted) return;
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
    _reanchorSelectionOnGrowth();
    _syncMouseTracking();
    _syncHasSelection();
    // #726: the visible buffer may have changed (output/scroll) — re-detect URLs
    // on a debounce so a streaming burst doesn't re-scan every byte.
    _scheduleUrlDetect();
  }

  /// #726: debounce a URL re-detection. The controller fires on every output
  /// write; coalesce a burst into one scan ~120ms after the last notify so
  /// streaming output stays cheap. A short delay also lets flterm settle the
  /// grid before we read it. Cancelled/replaced on each notify; cleared on
  /// dispose.
  void _scheduleUrlDetect() {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 120), _detectUrls);
  }

  /// #726: read the VISIBLE viewport text from flterm and re-detect URLs.
  ///
  /// The buffer READ uses flterm's public
  /// `controller.createFormatter(format: plain, unwrap: false).format()`, which
  /// returns the ACTIVE SCREEN (visible viewport, NOT scrollback) as plain text,
  /// one VISIBLE ROW per `\n`. We split on `\n` to get the per-row strings and
  /// hand them to the PURE [detectGhosttyUrls] matcher with the live grid width
  /// ([_cols]) — which re-joins soft-wrapped rows and maps each URL to a viewport
  /// cell range. Only rebuilds when the match list actually changes (the painter
  /// + tap hit-test read [_urlMatches]). Defensive: a formatter/FFI error must
  /// never crash the session, so it falls back to no highlights.
  void _detectUrls() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    List<GhosttyUrlMatch> next;
    try {
      final formatter = controller.createFormatter(
        format: FormatterFormat.plain,
        unwrap: false,
      );
      final String text;
      try {
        text = formatter.format();
      } finally {
        formatter.dispose();
      }
      final rows = text.split('\n');
      next = detectGhosttyUrls(rows, cols: _cols);
    } catch (_) {
      // A formatter/FFI hiccup must not crash the session — drop highlights.
      next = const [];
    }
    if (GhosttyUrlHighlightPainter._sameMatches(_urlMatches, next)) return;
    if (mounted) setState(() => _urlMatches = next);
  }

  /// #712: mirror whether a selection is active into [_hasSelection], rebuilding
  /// only when it actually toggles (the controller notifies on many unrelated
  /// events too) so the bottom-right affordance buttons show ONLY while a
  /// selection exists. Runs AFTER [_reanchorSelectionOnGrowth], which may CLEAR a
  /// fully-evicted selection, so this reads the post-re-anchor state.
  void _syncHasSelection() {
    final controller = _controller;
    if (controller == null) return;
    final next = controller.selection != null;
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
    _sendResize(_cols, _rows);
    gtrace('ghostty-resync $trigger: cols=$_cols rows=$_rows');
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
    _lastSentCols = cols;
    _lastSentRows = rows;
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
      gtrace('ghostty-resume-repaint: focus-cycled (no keyboard)');
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
    // #706 (issue 1): record the scrollback length this selection is anchored
    // against, so a later eviction can be detected and the rows shifted.
    _selScrollbackLen =
        controller.scrollbar.total - controller.scrollbar.visible;
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
    // #706: capture the scrollback length the selection was anchored against,
    // so [_reanchorSelectionOnGrowth] can detect later EVICTION and shift the
    // absolute rows to keep the highlight on the same content.
    _selScrollbackLen =
        controller.scrollbar.total - controller.scrollbar.visible;
  }

  /// #706 (issue 2): clear the active flterm LOCAL selection and forget the
  /// content anchor. Invoked when a single tap lands while a selection is
  /// active (the tap is then swallowed). Idempotent.
  void _clearSelection() {
    final controller = _controller;
    if (controller == null) return;
    controller.clearSelection();
    _selAnchorCol = null;
    _selAnchorRow = null;
    _selScrollbackLen = null;
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

  /// #726: copy a tapped URL to the clipboard + confirm via a top-toast. Invoked
  /// when a single tap lands on a highlighted URL (the tap is swallowed).
  Future<void> _copyUrl(GhosttyUrlMatch match) async {
    await Clipboard.setData(ClipboardData(text: match.url));
    if (mounted) showTopToast(context, 'Copied URL');
  }

  /// #734: show the Copy/Open action menu for a long-pressed URL — the SAME
  /// `showUrlActions` overlay (`url_action_overlay.dart`, keys `url-action-menu`/
  /// `url-action-copy`/`url-action-open`) the xterm path uses, so Copy →
  /// clipboard + toast and Open → `launchUrl` (external). Reuses the detected
  /// [match] ranges (#726) — no duplicate detection.
  ///
  /// Builds the URL's on-screen highlight rects from the match's 0-based viewport
  /// cell range using the SAME geometry the [GhosttyUrlHighlightPainter] +
  /// gesture router use: [kGhosttyTerminalPadding] + the live [_lastCellSize],
  /// then offset by the view's render-box GLOBAL origin (the overlay layer is
  /// rooted, so it wants global coords). A soft-wrapped URL spans rows → one rect
  /// per row segment, mirroring [ghosttyCellInUrl]'s geometry.
  void _showUrlMenu(GhosttyUrlMatch match, Offset globalAnchor) {
    if (!mounted) return;
    final rects = _urlGlobalRects(match);
    showUrlActions(
      context,
      match.url,
      highlightRects: rects,
      anchor: globalAnchor,
    );
  }

  /// The GLOBAL on-screen rects for [match]'s cell range (#734). One per row the
  /// URL occupies: the start row's tail, every interior row full-width, the end
  /// row's head — matching [ghosttyCellInUrl]'s hit-test geometry. Empty (the
  /// menu still shows, anchored at the press) if the layout isn't measurable yet.
  List<Rect> _urlGlobalRects(GhosttyUrlMatch match) {
    final cell = _lastCellSize;
    if (cell.width <= 0 || cell.height <= 0) return const [];
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return const [];
    final origin = box.localToGlobal(Offset.zero);
    final cols = _cols > 0 ? _cols : _lastSentCols;
    final rects = <Rect>[];
    for (var row = match.startRow; row <= match.endRow; row++) {
      final startCol = row == match.startRow ? match.startCol : 0;
      final endCol = row == match.endRow
          ? match.endCol
          : (cols > 0 ? cols : match.endCol);
      if (endCol <= startCol) continue;
      final left = kGhosttyTerminalPadding + startCol * cell.width;
      final top = kGhosttyTerminalPadding + row * cell.height;
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
    // #706 (issue 1): anchor the content-tracking baseline so a Select-all span
    // is re-offset on eviction too (and a tap dismisses it like any selection).
    _selAnchorCol = null;
    _selAnchorRow = null;
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
    _urlDebounce?.cancel();
    _outputSub?.cancel();
    _controller?.removeListener(_onControllerChanged);
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
    // #741: a session-bar swipe-switch must leave the keyboard state UNCHANGED.
    // The IndexedStack moves the outgoing focused view offstage (its TextInput
    // detaches → keyboard collapses) and never focuses the incoming view, so the
    // bar jumps down out from under the finger. Each view listens for the active
    // session changing: the OUTGOING view captures its keyboard-up state; the
    // INCOMING view re-attaches focus and re-shows the keyboard iff it was up.
    ref.listen<String?>(activeSessionIdProvider, (prev, next) {
      _onActiveSessionChanged(prev, next);
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
        // #726: URL highlight overlay — a subtle underline under each detected
        // URL's cell range, drawn with the SAME #723-correct cell metrics + the
        // flterm padding so it lands under the on-screen text. IgnorePointer so
        // it never steals the tap (the gesture router below handles tap-to-copy).
        // Repaints when _urlMatches / metrics change (debounced re-detection on
        // controller notify), so it follows scroll + resize. Uses the theme's
        // selection colour for theme consistency (#716).
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: GhosttyUrlHighlightPainter(
                matches: _urlMatches,
                cellWidth: cellSize.width,
                cellHeight: cellSize.height,
                cols: _cols,
                color: palette.theme.selection,
              ),
            ),
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
            // #706 (issue 2): a single tap dismisses an active selection and is
            // swallowed. The parent owns the controller, so it answers "is a
            // selection active?" live and clears it on demand.
            hasSelection: () => controller.selection != null,
            onSelectionClear: _clearSelection,
            // #726: resolve a tapped cell to a detected URL (0-based viewport
            // cells) and copy it on tap. The parent owns _urlMatches.
            urlAtCell: (col, row) =>
                ghosttyUrlAtCell(_urlMatches, col: col, row: row),
            onUrlTap: _copyUrl,
            // #734: a long-press on a detected URL shows the Copy/Open action
            // menu (the same `showUrlActions` overlay the xterm path uses). The
            // parent builds the on-screen highlight rects + anchor from the match
            // and hands them to the overlay.
            onUrlLongPress: _showUrlMenu,
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
        if (ghosttyShouldShowAffordances(hasSelection: _hasSelection))
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
