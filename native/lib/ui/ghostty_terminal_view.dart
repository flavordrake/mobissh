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
// [_ScrollInsteadOfMouseDrag] / [ghosttySwipeShouldScrollLocally]. The wheel
// reports flterm emits for an actual scroll ARE correct (libghostty's own SGR
// wheel encoding, not xterm-4.0.0's buggy 68/69 — so no #617-style fix is needed
// for the wheel path here).
//
// flterm re-exports libghostty's `Key` input enum, which collides with
// Flutter's widget `Key`. We only use Flutter's, so hide flterm's.

import 'dart:async';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
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

/// DEFAULT (scroll-only) gesture settings for the ghostty backend (#688).
///
/// #686 dropped `SelectionGesture.drag` but a finger SWIPE STILL drag-selected
/// a multi-line block. Root cause: flterm gives `drag` to MOUSE pointers and
/// `longPress` to TOUCH pointers (terminal_raw_gesture_detector.dart), and on a
/// swipe the brief start-of-swipe dwell makes the touch `LongPressGestureRecognizer`
/// win the gesture arena — `onLongPressMoveUpdate` then paints a selection AND
/// auto-scrolls. So `longPress`, not `drag`, was the swipe culprit.
///
/// To make a swipe SCROLL-ONLY we drop BOTH `drag` and `longPress` here, leaving
/// no touch DRAG-select gesture. A swipe now only drives the inner `Scrollable`:
///
///   - vertical SWIPE -> SCROLL the scrollback (flterm's `Scrollable`), no select
///   - double-tap     -> select word   (discrete tap; never fires on a swipe)
///   - triple-tap     -> select line   (discrete tap; never fires on a swipe)
///   - Ctrl/Cmd+A     -> select all
///
/// Deliberate long-press-drag selection is opt-in via [kGhosttySelectSettings]
/// (the "select mode" toggle). `lineSelectMode.full` keeps line/triple-tap
/// selection grabbing the FULL row width (trailing blanks included).
const TerminalGestureSettings kGhosttyScrollSettings = TerminalGestureSettings(
  enabledSelections: {
    SelectionGesture.word,
    SelectionGesture.line,
    SelectionGesture.selectAll,
  },
  lineSelectMode: LineSelectMode.full,
);

/// SELECT-MODE gesture settings for the ghostty backend (#688).
///
/// Active only while the user has toggled "select mode" on. Re-enables flterm's
/// native touch `longPress` so a deliberate long-press-then-drag starts and
/// extends a selection. Everything else matches [kGhosttyScrollSettings].
///
/// flterm limitation (#688): even here, a long-press-drag that reaches the
/// viewport edge will auto-scroll (`_updateDrag` in flterm's gesture detector),
/// and flterm 0.0.3 exposes no draggable endpoint handles — so the "deliberate"
/// gate is the MODE, not a finer in-gesture distinction.
const TerminalGestureSettings kGhosttySelectSettings = TerminalGestureSettings(
  enabledSelections: {
    SelectionGesture.longPress,
    SelectionGesture.word,
    SelectionGesture.line,
    SelectionGesture.selectAll,
  },
  lineSelectMode: LineSelectMode.full,
);

/// Whether a touch SWIPE should be intercepted and turned into a local scroll
/// instead of being forwarded to the remote PTY as a mouse-button DRAG (#690).
///
/// flterm forwards swipes as button1 press+motion+release ONLY when the remote
/// has mouse tracking on (`mouseTracking != MouseTracking.none`). When the user
/// has DELIBERATELY entered select mode we leave flterm's native gestures alone
/// (so a long-press-drag still works, mirroring #688). So the swipe-scroll
/// interception is active exactly when mouse tracking is on AND select mode is
/// off. Pure (no FFI), so it's unit-testable headless.
bool ghosttySwipeShouldScrollLocally({
  required MouseTracking mouseTracking,
  required bool selectMode,
}) {
  return mouseTracking != MouseTracking.none && !selectMode;
}

/// Map a vertical swipe DELTA (logical px the finger moved this update) to a
/// scrollback pixel delta to apply to the [TerminalScrollController] (#690).
///
/// A finger dragging DOWN (positive dy) reveals OLDER content, i.e. scrolls the
/// viewport UP toward smaller pixel offsets — so the scroll delta is the
/// negation of the finger delta, matching a natural touch-scroll. Pure.
double ghosttyScrollDeltaForSwipe(double fingerDy) => -fingerDy;

/// A gesture layer that absorbs touch swipes and drives a
/// [TerminalScrollController] directly, so the swipe SCROLLS the scrollback
/// instead of flterm forwarding it to the remote PTY as a button1 DRAG (#690).
///
/// Active only while [active] is true (see [ghosttySwipeShouldScrollLocally]).
///
/// Why OPAQUE, not translucent: flterm reports tracked mouse via a raw
/// `Listener` (onPointerDown/Move/Up), which is NOT a gesture-arena participant
/// — so merely WINNING the arena for the drag would not stop flterm from also
/// emitting button press/motion on the same pointer. The only way to keep the
/// swipe off flterm's `Listener` is to be the opaque hit-test target so the
/// pointer never reaches the terminal below. Because that also swallows taps, we
/// add a tap recognizer that forwards focus via [onTap] (so tapping still raises
/// the keyboard) while the vertical-drag recognizer (touch-only) does the scroll.
///
/// When [active] is false (mouse mode off, or deliberate select mode on) it is
/// inert (`IgnorePointer`), so flterm's native scroll/selection is untouched.
class _ScrollInsteadOfMouseDrag extends StatefulWidget {
  const _ScrollInsteadOfMouseDrag({
    required this.active,
    required this.scrollController,
    required this.onTap,
  });

  /// Whether to intercept swipes (mouse tracking on AND select mode off).
  final bool active;

  /// The SAME controller handed to the flterm [TerminalView] — moving it routes
  /// through flterm's `_onScrollChanged` → wheel reports / local scroll.
  final TerminalScrollController scrollController;

  /// Forwarded on a tap so focus/keyboard still work while the overlay is the
  /// opaque hit-test target (typically `controller.requestFocus`).
  final VoidCallback onTap;

  @override
  State<_ScrollInsteadOfMouseDrag> createState() =>
      _ScrollInsteadOfMouseDragState();
}

class _ScrollInsteadOfMouseDragState extends State<_ScrollInsteadOfMouseDrag> {
  void _onUpdate(DragUpdateDetails details) {
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

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      // Inert: flterm's own gesture detector / Scrollable handles everything.
      return const IgnorePointer(child: SizedBox.expand());
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
              (recognizer) => recognizer.onUpdate = _onUpdate,
            ),
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (recognizer) => recognizer.onTap = widget.onTap,
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

  /// Whether DELIBERATE selection mode is active (#688).
  ///
  /// `false` (default): a swipe SCROLLS only — [kGhosttyScrollSettings], which
  /// has no touch drag-select gesture. `true`: [kGhosttySelectSettings] is
  /// applied, re-enabling flterm's native touch long-press-drag selection.
  /// Per-session (held on the widget state, not a global) so one session's
  /// select mode never leaks into another's.
  bool _selectMode = false;

  /// Toggle deliberate select mode. Leaving select mode clears any pending
  /// highlight so the user isn't left with a stale selection while scrolling.
  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) _controller?.clearSelection();
    });
    if (mounted) {
      showTopToast(
        context,
        _selectMode
            ? 'Select mode ON — long-press the terminal, then drag to select.'
            : 'Select mode OFF — swipe scrolls.',
      );
    }
  }

  @override
  void initState() {
    super.initState();
    final proxy = _resolveProxy();
    if (proxy == null) {
      _initError = 'No session for ${widget.sessionId}';
      return;
    }
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
      // pixel sizes default to 0 (the task isolate only needs cols/rows).
      controller.onResize = (cols, rows) {
        proxy.sendResize(cols, rows);
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

  Future<void> _copySelection() async {
    final controller = _controller;
    if (controller == null) return;
    final text = controller.selectedText();
    if (text.isEmpty) {
      if (mounted) {
        showTopToast(
          context,
          _selectMode
              ? 'No selection — long-press the terminal, then drag.'
              : 'No selection — turn on select mode first, then long-press.',
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
    return Stack(
      key: Key('ghostty-terminal-${widget.sessionId}'),
      children: [
        Positioned.fill(
          child: TerminalView(
            controller: controller,
            autofocus: false,
            theme: buildGhosttyTheme(family: fontFamily, fontSize: fontSize),
            padding: const EdgeInsets.all(4),
            // #690: share the scroll controller so the overlay below can drive
            // scrollback (→ flterm wheel reports) under remote mouse mode.
            scrollController: _scrollController,
            // #688: swipe = scroll-ONLY by default; deliberate long-press-drag
            // selection only while select mode is ON. See the two settings
            // objects' docs for the flterm root cause (touch long-press, not
            // `drag`, was the swipe-select culprit).
            gestureSettings: _selectMode
                ? kGhosttySelectSettings
                : kGhosttyScrollSettings,
          ),
        ),
        // #690: when the remote has mouse mode on (tmux etc.), a finger swipe
        // would otherwise be forwarded as a button1 DRAG → tmux selection. This
        // overlay claims the touch vertical-drag and scrolls the scrollback
        // (flterm then emits canonical wheel reports), so a swipe SCROLLS and
        // never drags. Inert when mouse mode is off or select mode is on, so
        // #688's gestures are untouched. Sits below the affordance buttons so
        // they stay tappable.
        Positioned.fill(
          child: _ScrollInsteadOfMouseDrag(
            active: ghosttySwipeShouldScrollLocally(
              mouseTracking: _mouseTracking,
              selectMode: _selectMode,
            ),
            scrollController: _scrollController,
            onTap: controller.requestFocus,
          ),
        ),
        // Selection affordances (bottom-right). flterm's long-press select
        // highlights cells; `selectedText()` pulls them to the clipboard.
        // Select-all is the best extra selection control flterm 0.0.3 exposes
        // (no draggable endpoint handles — see file header / TRACE).
        Positioned(
          right: 4,
          bottom: 4,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // #688: deliberate select-mode toggle. OFF (default) = swipe
              // scrolls only; ON = flterm native long-press-drag selection.
              Material(
                color: _selectMode ? Colors.green.shade700 : Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('ghostty-select-mode'),
                  tooltip: _selectMode
                      ? 'Select mode ON (tap to scroll)'
                      : 'Select mode OFF (tap to select)',
                  iconSize: 18,
                  icon: Icon(
                    _selectMode ? Icons.touch_app : Icons.touch_app_outlined,
                    color: Colors.white,
                  ),
                  onPressed: _toggleSelectMode,
                ),
              ),
              const SizedBox(height: 8),
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
