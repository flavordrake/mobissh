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
// flterm re-exports libghostty's `Key` input enum, which collides with
// Flutter's widget `Key`. We only use Flutter's, so hide flterm's.

import 'dart:async';

import 'package:flterm/flterm.dart' hide Key;
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

  /// PTY output (bytes) -> controller.write subscription. Cancelled on dispose.
  StreamSubscription<Uint8List>? _outputSub;

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
      _controller = controller;
    } catch (e) {
      // If libghostty's native .so failed to load, surface it instead of a
      // blank crash so the device tester can report it (mirrors the spike).
      _initError = 'flterm init failed: $e';
    }
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
    _controller?.onOutput = null;
    _controller?.onResize = null;
    _controller?.dispose();
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
            // #688: swipe = scroll-ONLY by default; deliberate long-press-drag
            // selection only while select mode is ON. See the two settings
            // objects' docs for the flterm root cause (touch long-press, not
            // `drag`, was the swipe-select culprit).
            gestureSettings: _selectMode
                ? kGhosttySelectSettings
                : kGhosttyScrollSettings,
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
