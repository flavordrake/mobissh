import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart' as vt;
import 'package:libghostty/libghostty.dart' hide KeyEvent, Listenable;
import 'package:meta/meta.dart';

import '../foundation.dart';
import '../rendering/kitty_png_decoder.dart';
import 'terminal_controller.dart';
import 'terminal_input_client.dart';
import 'terminal_view_binding.dart';

@internal
class TerminalControllerImpl extends TerminalController
    implements TerminalViewBinding {
  static const _cr = 0x0d;
  static const _del = 0x7f;
  static const _formFeed = 0x0c;
  static const _space = 0x20;
  static const _macFunctionKeyStart = 0xF700;
  static const _macFunctionKeyEnd = 0xF8FF;

  static final _crBytes = Uint8List.fromList([_cr]);
  static final _formFeedBytes = Uint8List.fromList([_formFeed]);
  static final _clearScrollback = utf8.encode('\x1b[3J');
  static final _appCursorDown = Uint8List.fromList([0x1b, 0x4f, 0x42]);
  static final _appCursorUp = Uint8List.fromList([0x1b, 0x4f, 0x41]);
  static final _cursorDown = Uint8List.fromList([0x1b, 0x5b, 0x42]);
  static final _cursorUp = Uint8List.fromList([0x1b, 0x5b, 0x41]);

  @override
  final Terminal terminal;
  final _renderState = RenderState();
  final _keyEncoder = KeyEncoder();
  final _mouseEncoder = MouseEncoder();
  final vt.KeyEvent _keyEvent;
  final MouseEvent _mouseEvent;
  final TerminalInputClient _textInput;

  TerminalConfig _config;
  TerminalScreen _activeScreen = .primary;
  MouseTracking _mouseTracking = .none;
  KeyboardState _keyboardState = .hidden;
  Mods _virtualMods = const .none();
  var _preeditText = '';
  var _cursorKeyApplication = false;
  Brightness _brightness = .dark;
  var _cursorBlinking = true;
  var _wasFocused = false;

  CellMetrics _lastMetrics = const .new(
    cellWidth: 0,
    cellHeight: 0,
    baseline: 0,
  );
  var _lastDevicePixelRatio = 1.0;

  /// #767 Slice B: the most recent grid padding (the [TerminalView] insets the
  /// grid by this). Stored so the anchor geometry resolver ([anchorRects]) lays
  /// out a range in the SAME padded, logical-pixel space the grid renders in, so
  /// a widget-layer decorator pixel-aligns to the glyph cells.
  EdgeInsets _lastPadding = EdgeInsets.zero;

  /// #803: the viewport offset the render box LAST PAINTED the text with — the
  /// SAME `viewportOffset` the [HighlightPainter] reads from the frame snapshot.
  /// [anchorRects] resolves against this (not the live `scrollbar.offset`) so the
  /// widget-layer URL bubble decorator stays in lockstep with the painted glyphs
  /// during a tmux-redraw scroll (the "dance" #803). Updated by
  /// [reportPaintedViewportOffset] each frame; the resulting notify is deferred
  /// to post-frame (the report fires during paint).
  int _paintedViewportOffset = 0;

  /// #803: guards against scheduling more than one post-frame notify when the
  /// render box reports a changed painted offset (it reports every frame).
  bool _paintedOffsetNotifyScheduled = false;

  /// #803: set in [dispose] so a pending post-frame notify (scheduled by
  /// [reportPaintedViewportOffset]) is a no-op if it fires after disposal.
  bool _disposed = false;

  /// #812: true while the PAINTED viewport offset is actively CHANGING (a scroll,
  /// including a tmux-redraw "scroll" where the remote rewrites the grid). Set on
  /// the rising edge in [reportPaintedViewportOffset]; flipped back to false by
  /// [_scrollSettleTimer]'s trailing edge after [_scrollSettleMs] of no offset
  /// change. The widget-layer decorator layer HIDES while this is true and SHOWS
  /// once it settles, so the decorator never draws during the moment it can't
  /// reliably track the offset — killing the off-by-line drift class (#784/#803/
  /// #807) by not drawing mid-scroll instead of chasing the offset.
  bool _isScrolling = false;

  /// #812: trailing-edge timer that flips [_isScrolling] back to settled. Reset on
  /// every painted-offset change; when it finally fires (no change for
  /// [_scrollSettleMs]) the offset is stable, painted==live, so the decorator can
  /// re-resolve + draw at the exact settled placement. Cancelled on dispose.
  Timer? _scrollSettleTimer;

  /// #812: how long the painted offset must hold still before the decorator is
  /// shown again. Within the 120–150ms range the owner specified — long enough to
  /// ride through a streaming tmux-redraw scroll (chunks ~8ms apart), short enough
  /// that the bubble reappears promptly once the user lifts off.
  static const int _scrollSettleMs = 140;

  /// #805: fires ONLY when a widget-layer decorator's inputs change — the
  /// detected [_detectionMatches] set (after a settled re-scan) or the
  /// [_paintedViewportOffset] (after a frame paints a new offset). A decorator
  /// layer listens to THIS instead of the controller's general notify, so it
  /// re-resolves anchor rects only when the decoration geometry actually moves,
  /// not on every one of the ~15 redraw notifies/sec a streaming TUI scroll
  /// emits. Exposed via [decorationListenable].
  final _DecorationNotifier _decorationNotifier = _DecorationNotifier();

  FocusNode? _focusNode;
  TerminalSelection? _selection;
  List<HighlightRange> _highlights = const [];
  ScrollController? _scrollController;

  /// #767: registered structured-text patterns keyed by [TextPattern.id], and
  /// the matches the last re-scan produced. The detection is owned HERE (not the
  /// app) so it reads the terminal's own cells and re-anchors across scroll /
  /// wrap / resize / eviction by re-scanning, mirroring how [_selection] /
  /// [_highlights] are controller-owned overlay state.
  final Map<String, TextPattern> _textPatterns = <String, TextPattern>{};
  List<StructuredMatch> _detectionMatches = const [];
  static const _detectionScanner = StructuredTextScanner();

  /// #767: debounce for the cell re-scan. The terminal notifies on every output
  /// write AND every scroll; coalesce a burst into one scan so streaming output
  /// doesn't re-scan every byte. Cancelled on dispose.
  Timer? _detectionDebounce;

  /// #767: how many scrollback rows ABOVE the active viewport the re-scan reads.
  /// Bounded so detection never walks unbounded history on every notify — only
  /// the active screen plus this many recent scrollback rows are scanned, which
  /// covers a URL the user just scrolled near without an O(scrollback) cost.
  static const int _detectionScrollbackWindow = 200;

  /// #767: debounce window (ms) for the cell re-scan. Mirrors the app's old
  /// 120ms URL re-detect debounce, now owned by the controller.
  static const int _detectionDebounceMs = 120;

  TerminalControllerImpl({TerminalConfig config = const TerminalConfig()})
    : _config = config,
      _keyEvent = vt.KeyEvent(),
      _mouseEvent = MouseEvent(),
      _textInput = TerminalInputClient(),
      terminal = Terminal(
        cols: config.cols,
        rows: config.rows,
        maxScrollback: config.scrollbackLimit,
      ),
      super.base() {
    installDefaultKittyPngDecoder();
    _applyTerminalOptions();
    _textInput
      ..onTextCommitted = _handleTextCommitted
      ..onDelete = _handleDelete
      ..onPreeditChanged = _handlePreeditChanged
      ..onNewline = _handleNewline;
    _wireTerminalCallbacks();
    _applyModes();
    terminal.addListener(_onTerminalChanged);
  }

  @override
  TerminalScreen get activeScreen => _activeScreen;

  @override
  set brightness(Brightness value) {
    _textInput.keyboardAppearance = value;
    _brightness = value;
  }

  @override
  TerminalConfig get config => _config;

  @override
  set config(TerminalConfig value) {
    if (_config == value) return;
    _config = value;
    _applyTerminalOptions();
    _applyModes();
    _wireTerminalCallbacks();
    notifyListeners();
  }

  @override
  bool get cursorBlinks {
    if (!_cursorBlinking || !hasFocus) return false;
    if (_activeScreen == .alternate) return true;
    final sc = _scrollController;
    if (sc == null || !sc.hasClients) return true;
    final pos = sc.position;
    if (!pos.hasContentDimensions) return true;
    return pos.pixels >= pos.maxScrollExtent - 1.0;
  }

  @override
  bool get hasFocus => _focusNode?.hasFocus ?? false;

  @override
  KeyboardState get keyboardState => _keyboardState;

  @override
  MouseTracking get mouseTracking => _mouseTracking;

  @override
  String get preeditText => _preeditText;

  @override
  String get pwd => terminal.pwd;

  @override
  int get scrollbackRows => terminal.scrollbackRows;

  @override
  Scrollbar get scrollbar => terminal.scrollbar;

  @override
  TerminalSelection? get selection => _selection;

  @override
  set selection(TerminalSelection? value) {
    if (_selection == value) return;
    _selection = value;
    notifyListeners();
  }

  @override
  List<HighlightRange> get highlights => _highlights;

  @override
  set highlights(List<HighlightRange> value) {
    if (identical(_highlights, value)) return;
    _highlights = value;
    notifyListeners();
  }

  @override
  HighlightRange? highlightAt({required int row, required int col}) {
    if (_highlights.isEmpty) return null;
    final absRow = row + scrollbar.offset;
    HighlightRange? match;
    for (final range in _highlights) {
      if (range.contains(absRow, col)) match = range;
    }
    return match;
  }

  @override
  void registerTextPattern(TextPattern pattern) {
    _textPatterns[pattern.id] = pattern;
    // Scan synchronously so a freshly-registered pattern highlights any URLs
    // already on screen without waiting for the next output/scroll notify.
    _rescanDetections();
  }

  @override
  void clearTextPatterns() {
    if (_textPatterns.isEmpty && _detectionMatches.isEmpty) return;
    _textPatterns.clear();
    _detectionDebounce?.cancel();
    _detectionMatches = const [];
    // Clear only the detection-driven highlights (which are the only writer of
    // _highlights once a pattern is registered).
    highlights = const [];
  }

  @override
  StructuredMatch? matchAt({required int row, required int col}) {
    if (_detectionMatches.isEmpty) return null;
    final absRow = row + scrollbar.offset;
    final snappedCol = terminal.snapColToWideBoundary(
      row,
      col,
      inclusive: true,
    );
    StructuredMatch? match;
    for (final m in _detectionMatches) {
      if (m.contains(absRow, snappedCol)) match = m;
    }
    return match;
  }

  @override
  List<StructuredAnchor> get anchors {
    if (_detectionMatches.isEmpty) return const [];
    return [for (final m in _detectionMatches) StructuredAnchor.fromMatch(m)];
  }

  @override
  int get paintedViewportOffset => _paintedViewportOffset;

  @override
  bool get isScrolling => _isScrolling;

  @override
  Listenable get decorationListenable => _decorationNotifier;

  @override
  void reportPaintedViewportOffset(int offset) {
    if (offset == _paintedViewportOffset) return;
    _paintedViewportOffset = offset;
    // #812: the painted offset just moved → we are scrolling. Enter the scrolling
    // state (the decorator HIDES) and (re)arm the trailing-edge settle timer; each
    // further offset change pushes the settle out, so a streaming tmux-redraw
    // scroll stays "scrolling" for its whole duration. The decorator re-shows only
    // once the offset holds still for [_scrollSettleMs].
    _markScrolling();
    // This fires DURING the render box's paint phase, so a synchronous
    // notifyListeners() would rebuild the decorator layer mid-frame (illegal).
    // Defer to a post-frame callback: the decorator then re-resolves its rects
    // against the offset this frame just painted, landing one frame after the
    // glyphs but in lockstep with them — no "dance" ahead of the text (#803).
    if (_paintedOffsetNotifyScheduled) return;
    _paintedOffsetNotifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _paintedOffsetNotifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
      // #805: the painted offset moved, so any on-screen anchor's rects shift —
      // wake the narrow decoration listener so the decorator re-resolves in
      // lockstep with the painted glyphs (#803). But ONLY when anchors exist:
      // with nothing detected there is no decoration to move, so a full-repaint
      // TUI scroll that hasn't surfaced a URL/path doesn't rebuild the (empty)
      // decorator layer on every frame.
      if (_detectionMatches.isNotEmpty) _decorationNotifier.notify();
    });
  }

  /// #812: enter (or stay in) the scrolling state and (re)arm the trailing-edge
  /// settle timer. Called from [reportPaintedViewportOffset], which runs DURING
  /// the render box's paint phase — so this MUST NOT notify synchronously (that
  /// would schedule a build mid-frame). It only flips the flag + (re)arms the
  /// timer; the HIDE rebuild is driven by the post-frame `_decorationNotifier`
  /// notify already scheduled in [reportPaintedViewportOffset] (which fires when
  /// anchors exist — exactly when there is a bubble to hide). Each call pushes the
  /// settle out by [_scrollSettleMs], so a streaming redraw scroll stays hidden
  /// for its whole duration; [_onScrollSettled] (a Timer callback, not in paint)
  /// shows it again.
  void _markScrolling() {
    if (_disposed) return;
    // No registered patterns → no decoration to hide/show → don't track scroll
    // state at all (and don't arm a timer). Mirrors [_scheduleDetectionRescan]'s
    // no-op, and keeps a pattern-less terminal from leaving a settle timer pending
    // at the end of a widget test that never registers a decorator.
    if (_textPatterns.isEmpty) return;
    _isScrolling = true;
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = Timer(
      const Duration(milliseconds: _scrollSettleMs),
      _onScrollSettled,
    );
  }

  /// #812: trailing edge — the painted offset has held still for [_scrollSettleMs].
  /// Leave the scrolling state and wake the decoration listener ONCE so the
  /// decorator rebuilds and SHOWS, re-resolving anchor rects at the now-stable
  /// painted offset (painted == live → exact placement, no drift).
  void _onScrollSettled() {
    _scrollSettleTimer = null;
    if (_disposed || !_isScrolling) return;
    _isScrolling = false;
    _decorationNotifier.notify();
  }

  @override
  List<Rect> anchorRects(HighlightRange range) {
    final metrics = _lastMetrics;
    if (metrics.cellWidth <= 0 || metrics.cellHeight <= 0) return const [];
    _renderState.update(terminal);
    // The grid padding offsets every cell rect into the TerminalView's local
    // space, so a widget-layer decorator pixel-aligns to the glyphs. The pure
    // [AnchorGeometry] does the offset/clip math (unit-tested headless); this
    // wrapper supplies the live metrics/dimensions from FFI.
    //
    // #803: resolve against the PAINTED viewport offset (the frame snapshot the
    // HighlightPainter uses), NOT the live `scrollbar.offset`. During a tmux
    // mouse-mode scroll the content is rewritten via output bytes and the live
    // offset/anchors can move a frame AHEAD of the painted glyphs; pinning the
    // decorator to the painted offset keeps the bubble in lockstep with the text
    // it hugs. The render box reports this offset each frame and the controller
    // notifies post-frame, so a decorator built over these rects still tracks
    // scroll (#784) and re-detection (#788) — just frame-synced, not ahead.
    return AnchorGeometry.rectsFor(
      range,
      metrics: metrics,
      viewportOffset: _paintedViewportOffset,
      cols: _renderState.cols,
      viewportRows: _renderState.rows,
      origin: Offset(_lastPadding.left, _lastPadding.top),
    );
  }

  @override
  int? anchorGutterRow(HighlightRange range) {
    _renderState.update(terminal);
    return AnchorGeometry.gutterRowFor(
      range,
      viewportOffset: scrollbar.offset,
      viewportRows: _renderState.rows,
    );
  }

  /// #767: schedule a DEBOUNCED cell re-scan. Driven by [_onTerminalChanged]
  /// (the same notify cycle as highlights), so streaming output / scrolling
  /// coalesce into one scan. No-op when no pattern is registered.
  void _scheduleDetectionRescan() {
    if (_textPatterns.isEmpty) return;
    _detectionDebounce?.cancel();
    _detectionDebounce = Timer(
      const Duration(milliseconds: _detectionDebounceMs),
      _rescanDetections,
    );
  }

  /// #767: re-scan the active screen plus a bounded scrollback window for every
  /// registered pattern, store the matches, and ASSIGN the resulting absolute-
  /// coordinate ranges to [highlights] (the existing painter draws them). A
  /// fresh scan emits absolute rows from the CURRENT scrollback length, so
  /// scrollback eviction is corrected by construction (no ghost mark). Defensive:
  /// a formatter/FFI hiccup must never crash the session, so it falls back to no
  /// detection.
  void _rescanDetections() {
    if (_textPatterns.isEmpty) {
      _detectionMatches = const [];
      return;
    }
    // #824: HEURISTIC structured-text detection (the regex `url`/`path` patterns)
    // is for SHELL OUTPUT, not full-screen alt-screen apps (vim/less/htop use DEC
    // `?1049h`/`?1047h`). On the alternate screen a `~/.ssh/config` the user is
    // EDITING in vim isn't navigable and the underline is pure noise, so the
    // regex patterns are suppressed there. APP-DECLARED OSC-8 hyperlinks
    // (`isOsc8Source`) are NOT suppressed: an alt-screen TUI that emits a real
    // OSC-8 link (the owner's tap-to-copy case, #810) deliberately marked it
    // clickable, so it stays detectable/copyable. The Claude-CLI / repainting-TUI
    // URL case repaints the PRIMARY screen (#803) and is unaffected on either
    // count. Detection of the regex patterns resumes on returning to the primary
    // screen — `_onTerminalChanged` re-scans on the alternate->primary transition.
    final scanPatterns = _activeScreen == .alternate
        ? [for (final p in _textPatterns.values) if (p.isOsc8Source) p]
        : _textPatterns.values.toList(growable: false);
    if (scanPatterns.isEmpty) {
      // On the alt-screen with no OSC-8 source registered there is nothing to
      // detect; drop any anchors carried over from the primary screen so the
      // underlines vanish the instant vim opens, and wake the decorator.
      if (_detectionMatches.isEmpty) return;
      _detectionMatches = const [];
      highlights = const [];
      _decorationNotifier.notify();
      return;
    }
    List<StructuredMatch> matches;
    try {
      _renderState.update(terminal);
      final visibleRows = _renderState.rows;
      final cols = _renderState.cols;
      if (visibleRows <= 0 || cols <= 0) {
        matches = const [];
      } else {
        // Scan the region that is ACTUALLY ON SCREEN wherever the viewport
        // currently sits in scrollback, not a range anchored only to the bottom.
        // The viewport's top absolute row is the scroll offset; it occupies
        // [viewportTop, viewportTop + visibleRows). Scan that plus up to
        // _detectionScrollbackWindow rows of margin ABOVE and BELOW it, so a URL
        // the user scrolled far up to (#787) — or just scrolled near — is picked
        // up, while the bounded margin keeps this off an O(scrollback) walk.
        // (Anchored-to-bottom previously missed anything scrolled past the
        // window.) The margin also gives the wrap-join enough context rows above
        // the first visible row to assemble a URL that wraps across the boundary.
        final scrollback = terminal.scrollbackRows;
        final viewportTop = scrollbar.offset;
        final startAbs = viewportTop - _detectionScrollbackWindow < 0
            ? 0
            : viewportTop - _detectionScrollbackWindow;
        // Clamp the bottom to the last buffer row so we never read past the
        // active screen (defensive; the reader also guards per-cell).
        final maxEndAbs = scrollback + visibleRows; // exclusive
        var endAbs = viewportTop + visibleRows + _detectionScrollbackWindow;
        if (endAbs > maxEndAbs) endAbs = maxEndAbs;
        final reader = _ScreenCellReader(
          terminal: terminal,
          cols: cols,
          startAbsRow: startAbs,
          endAbsRow: endAbs,
        );
        matches = _detectionScanner.scan(reader, scanPatterns);
      }
    } catch (_) {
      matches = const [];
    }
    _detectionMatches = matches;
    highlights = [for (final m in matches) ...m.ranges];
    // #805: the detected anchor set just changed (a settled re-scan), so wake the
    // narrow decoration listener — the decorator layer re-resolves now, not on
    // every mid-scroll redraw notify. (highlights= already fired the general
    // notify for the built-in HighlightPainter.)
    _decorationNotifier.notify();
  }

  @override
  List<bool> get viewportRowWraps {
    _renderState.update(terminal);
    final rows = _renderState.rows;
    if (rows <= 0) return const [];
    final wraps = List<bool>.filled(rows, false);
    // The bottom visible row can never soft-wrap into a row below the viewport,
    // so leave its flag false and only probe rows above it.
    for (var r = 0; r < rows - 1; r++) {
      final ref = GridRef.at(terminal, col: 0, row: r);
      wraps[r] = ref.rowWrap;
      ref.dispose();
    }
    return wraps;
  }

  @override
  String get title => terminal.title;

  @override
  int get totalRows => terminal.totalRows;

  @override
  Mods get virtualMods => _virtualMods;

  bool get _hasActiveComposition =>
      _textInput.hasActiveComposition || _preeditText.isNotEmpty;

  bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      .linux || .macOS || .windows => true,
      .android || .fuchsia || .iOS => false,
    };
  }

  bool get _shouldForwardCompositionKeyToTextInput {
    return _hasActiveComposition && _textInput.isAttached && _isDesktopPlatform;
  }

  @override
  void attach(FocusNode focusNode, ScrollController scrollController) {
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode = focusNode;
    _wasFocused = focusNode.hasFocus;
    _focusNode!.addListener(_onFocusChanged);
    _textInput.keyboardAppearance = _brightness;
    if (_wasFocused && _keyboardState != .disabled) {
      if (_keyboardState == .showing) {
        _textInput.show();
      } else {
        _textInput.ensureAttached(keyboardAppearance: _brightness);
      }
    }
    _scrollController?.removeListener(_onScrollChanged);
    _scrollController = scrollController;
    _scrollController!.addListener(_onScrollChanged);
  }

  /// #784: a scrollback scroll moves the viewport via the [ScrollController] →
  /// the render object's `_onScroll` → `terminal.scrollViewport`, which does NOT
  /// fire the terminal's listeners, so this controller never re-notified and the
  /// widget-layer structured-text decorators kept rects resolved at the OLD
  /// offset while the fork's painter (reading the offset from the frame snapshot)
  /// moved — the outline drifted off its glyphs in scrollback. Forwarding the
  /// scroll notify here rebuilds the decorator layer, which re-resolves
  /// [anchorRects] against the live offset in the next build (after the render
  /// object has applied the scroll), so the outline tracks the glyphs.
  ///
  /// #787: a scroll also moves the visible region, so the detection scan window
  /// (now centred on the viewport, not anchored to the bottom) must be
  /// re-evaluated — otherwise a URL the user scrolled UP to, beyond the last
  /// scanned range, is never detected. Schedule the same debounced rescan the
  /// output path uses so a scroll burst coalesces into one scan.
  void _onScrollChanged() {
    _scheduleDetectionRescan();
    notifyListeners();
  }

  @override
  void clear() {
    if (_activeScreen == .alternate) return;
    clearSelection();
    terminal.write(_clearScrollback);
    _emitOutput(_formFeedBytes);
  }

  @override
  void clearSelection() => selection = null;

  @override
  void clearVirtualMods() {
    if (_virtualMods.isEmpty) return;
    _virtualMods = const .none();
    notifyListeners();
  }

  @override
  Formatter createFormatter({
    required FormatterFormat format,
    bool unwrap = false,
    bool trim = false,
    FormatterExtra extra = const FormatterExtra(),
  }) {
    return Formatter(
      terminal: terminal,
      format: format,
      unwrap: unwrap,
      trim: trim,
      extra: extra,
    );
  }

  @override
  void detach() {
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode = null;
    _wasFocused = false;
    _keyboardState = .hidden;
    _preeditText = '';
    _scrollController?.removeListener(_onScrollChanged);
    _scrollController = null;
    _textInput.detach();
  }

  @override
  void disableKeyboard() => _updateKeyboardState(.disabled);

  @override
  void dispose() {
    _disposed = true;
    _detectionDebounce?.cancel();
    _scrollSettleTimer?.cancel();
    terminal.removeListener(_onTerminalChanged);
    detach();
    _keyEvent.dispose();
    _mouseEvent.dispose();
    _keyEncoder.dispose();
    _mouseEncoder.dispose();
    _renderState.dispose();
    _decorationNotifier.dispose();
    terminal.dispose();
    super.dispose();
  }

  @override
  KeyEventResult handleKeyEvent(KeyEvent event) {
    if (!_hasActiveComposition &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        HardwareKeyboard.instance.isShiftPressed &&
        _selection != null) {
      if (_extendSelection(event.logicalKey)) return .handled;
    }

    final key = keyFromPhysical(event.physicalKey);
    final KeyAction? action = switch (event) {
      KeyDownEvent() => .press,
      KeyUpEvent() => .release,
      KeyRepeatEvent() => .repeat,
      _ => null,
    };

    if (action == null) return .ignored;

    if (_shouldForwardCompositionKeyToTextInput) {
      return .skipRemainingHandlers;
    }

    final unshiftedCodepoint = unshiftedCodepointForKey(key);
    final mods = _currentMods();
    final character = _encoderCharacter(event.character);
    final consumedMods = _consumedModsFor(
      character,
      unshiftedCodepoint: unshiftedCodepoint,
      mods: mods,
    );

    _keyEvent
      ..key = key
      ..mods = mods
      ..action = action
      ..utf8 = character
      ..consumedMods = consumedMods
      ..unshiftedCodepoint = unshiftedCodepoint
      ..composing = _hasActiveComposition;

    _keyEncoder.sync(terminal);
    final result = _keyEncoder.encode(_keyEvent);
    if (result.isEmpty) return _hasActiveComposition ? .handled : .ignored;

    if (_shouldRouteKeyThroughTextInput(
      action: action,
      character: character,
      encoded: result,
      mods: mods,
    )) {
      _onTextInput();
      return .skipRemainingHandlers;
    }

    clearVirtualMods();
    final forwardToPlatformIme = _consumeCommittedCompositionEditKey(
      key,
      action,
      mods,
    );
    _emitOutput(utf8.encode(result));
    _onTextInput();

    return forwardToPlatformIme ? .skipRemainingHandlers : .handled;
  }

  @override
  void handleMouseEvent(TerminalMouseEvent event) {
    _mouseEvent
      ..action = event.action
      ..button = event.button
      ..mods = _currentMods()
      ..setPosition(
        x: event.pixelX * _lastDevicePixelRatio,
        y: event.pixelY * _lastDevicePixelRatio,
      );
    _mouseEncoder.sync(terminal);
    final result = _mouseEncoder.encode(_mouseEvent);
    if (result.isEmpty) return;
    _emitOutput(utf8.encode(result));
  }

  @override
  void handleResize({
    required int cols,
    required int rows,
    required CellMetrics metrics,
    required EdgeInsets padding,
    required double devicePixelRatio,
  }) {
    _lastMetrics = metrics;
    _lastPadding = padding;
    _lastDevicePixelRatio = devicePixelRatio;
    final cellWidthPx = (metrics.cellWidth * devicePixelRatio).round();
    final cellHeightPx = (metrics.cellHeight * devicePixelRatio).round();
    _mouseEncoder.setSize(
      MouseEncoderSize(
        screenWidth: cols * cellWidthPx,
        screenHeight: rows * cellHeightPx,
        cellWidth: cellWidthPx,
        cellHeight: cellHeightPx,
        paddingLeft: (padding.left * devicePixelRatio).round(),
        paddingRight: (padding.right * devicePixelRatio).round(),
        paddingTop: (padding.top * devicePixelRatio).round(),
        paddingBottom: (padding.bottom * devicePixelRatio).round(),
      ),
    );
    onResize?.call(cols, rows);

    if (terminal.modeGet(const TerminalMode.inBandResize())) {
      final report = SizeReportStyle.mode2048.encode(
        rows: rows,
        columns: cols,
        cellWidth: cellWidthPx,
        cellHeight: cellHeightPx,
      );
      _emitOutput(utf8.encode(report));
    }
  }

  @override
  void handleScroll(int lines) {
    if (_activeScreen != .alternate || lines == 0) return;

    if (_mouseTracking != .none) {
      final button = lines < 0 ? MouseButton.four : MouseButton.five;
      final count = lines.abs();

      if (count > 0) _mouseEncoder.sync(terminal);

      for (var i = 0; i < count; i++) {
        _mouseEvent
          ..action = .press
          ..button = button
          ..mods = _currentMods()
          ..setPosition(x: 0, y: 0);
        final result = _mouseEncoder.encode(_mouseEvent);
        if (result.isNotEmpty) _emitOutput(utf8.encode(result));
      }
      return;
    }

    final up = _cursorKeyApplication ? _appCursorUp : _cursorUp;
    final down = _cursorKeyApplication ? _appCursorDown : _cursorDown;
    final key = lines < 0 ? up : down;
    final count = lines.abs();
    final bytes = Uint8List(key.length * count);
    for (var i = 0; i < count; i++) {
      bytes.setRange(i * key.length, (i + 1) * key.length, key);
    }
    _emitOutput(bytes);
  }

  @override
  void hideKeyboard() => _updateKeyboardState(.hidden);

  @override
  bool modeGet(TerminalMode mode) => terminal.modeGet(mode);

  @override
  void modeSet(TerminalMode mode, {required bool value}) {
    terminal.modeSet(mode, value: value);
  }

  @override
  void paste(String text) {
    if (text.isEmpty) return;
    final bracketed = terminal.modeGet(const .bracketedPaste());
    _emitOutput(pasteEncode(text, bracketed: bracketed));
    _scrollToBottomOnInput();
  }

  @override
  void requestFocus() => _focusNode?.requestFocus();

  @override
  void scrollToBottom() {
    if (_activeScreen == .alternate) return;
    terminal.scrollToBottom();
    final controller = _scrollController;
    if (controller != null && controller.hasClients) {
      final max = controller.position.maxScrollExtent;
      if (max.isFinite) controller.jumpTo(max);
    }
  }

  @override
  void scrollToTop() {
    if (_activeScreen == .alternate) return;
    terminal.scrollToTop();
    final controller = _scrollController;
    if (controller != null && controller.hasClients) controller.jumpTo(0);
  }

  @override
  void selectAll() {
    terminal.scrollToBottom();
    final scrollbackLen = terminal.scrollbackRows;
    _renderState.update(terminal);
    final rows = _renderState.rows;
    final cols = _renderState.cols;

    var lastScreenRow = -1;
    var lastContentCol = 0;
    for (var row = 0; row < rows; row++) {
      var rowLastCol = 0;
      for (var col = 0; col < cols; col++) {
        final ref = GridRef.at(terminal, col: col, row: row);
        final hasContent = ref.graphemes.isNotEmpty;
        ref.dispose();
        if (hasContent) rowLastCol = col + 1;
      }
      if (rowLastCol > 0) {
        lastScreenRow = row;
        lastContentCol = rowLastCol;
      }
    }

    if (lastScreenRow < 0 && scrollbackLen == 0) return;

    final int endRow;
    final int endCol;

    if (lastScreenRow >= 0) {
      endRow = scrollbackLen + lastScreenRow;
      endCol = lastContentCol;
    } else {
      endRow = scrollbackLen - 1;
      endCol = cols;
    }

    selection = TerminalSelection(
      startRow: 0,
      startCol: 0,
      endRow: endRow,
      endCol: endCol,
    );
  }

  @override
  String selectedText({FormatterFormat format = .plain}) {
    final selection = _selection;
    if (selection == null) return '';

    _renderState.update(terminal);
    final cols = _renderState.cols;
    final total = terminal.totalRows;
    if (cols <= 0 || total <= 0) return '';
    final topRow = selection.topRow.clamp(0, total - 1);
    final bottomRow = selection.bottomRow.clamp(0, total - 1);
    if (topRow > bottomRow) return '';

    final block = selection.mode == .block;
    final topCol = selection.topCol.clamp(0, cols - 1);
    final bottomCol = (selection.bottomCol - 1).clamp(0, cols - 1);
    if (block && topCol > bottomCol) return '';

    final formatter = Formatter(
      terminal: terminal,
      format: format,
      unwrap: !block,
      selection: Selection(
        startCol: topCol,
        startRow: topRow,
        endCol: bottomCol,
        endRow: bottomRow,
        rectangle: block,
        pointTag: .screen,
      ),
    );

    try {
      return formatter.format();
    } finally {
      formatter.dispose();
    }
  }

  @override
  void selectLine(int row, LineSelectMode lineSelectMode) {
    final (:startRow, :endRow, :endCol) = terminal.lineBoundaryAt(row);
    final int effectiveEndCol;
    switch (lineSelectMode) {
      case .full:
        _renderState.update(terminal);
        effectiveEndCol = _renderState.cols;
      case .content:
        effectiveEndCol = endCol;
    }
    selection = TerminalSelection(
      startRow: startRow,
      startCol: 0,
      endRow: endRow,
      endCol: effectiveEndCol,
    ).scroll(scrollbar.offset);
  }

  @override
  void selectWord(int row, int col) {
    final adjCol = terminal.snapColToWideBoundary(row, col, inclusive: true);
    final (startCol, endCol) = terminal.wordBoundaryAt(
      row,
      adjCol,
      wordPattern: _config.wordPattern,
    );
    selection = TerminalSelection(
      startRow: row,
      startCol: startCol,
      endRow: row,
      endCol: endCol,
    ).scroll(scrollbar.offset);
  }

  @override
  void sendKey(vt.Key key, {Mods mods = const .none()}) {
    final effectiveMods = mods | _virtualMods;
    final codepoint = unshiftedCodepointForKey(key);
    _keyEvent
      ..key = key
      ..mods = effectiveMods
      ..action = .press
      ..consumedMods = const .none()
      ..unshiftedCodepoint = codepoint
      ..utf8 = codepoint > 0 ? String.fromCharCode(codepoint) : null
      ..composing = false;

    _keyEncoder.sync(terminal);
    final result = _keyEncoder.encode(_keyEvent);
    if (result.isEmpty) return;
    _emitOutput(utf8.encode(result));
    clearVirtualMods();
  }

  @override
  void sendText(String text) {
    if (text.isEmpty) return;
    _emitOutput(utf8.encode(text));
    clearVirtualMods();
  }

  @override
  void showKeyboard() => _updateKeyboardState(.showing);

  @override
  void toggleMod(Mods mod) {
    _virtualMods = _virtualMods ^ mod;
    notifyListeners();
  }

  @override
  void unfocus() => _focusNode?.unfocus();

  @override
  void updateSelection(
    int startRow,
    int startCol,
    int endRow,
    int endCol,
    TerminalSelectionMode mode,
  ) {
    final (sc, ec) = terminal.snapSelectionCols(
      startRow,
      startCol,
      endRow,
      endCol,
    );
    selection = TerminalSelection(
      startRow: startRow,
      startCol: sc,
      endRow: endRow,
      endCol: ec,
      mode: mode,
    ).scroll(scrollbar.offset);
  }

  @override
  void updateTextInputGeometry({
    required Size editableSize,
    required Matrix4 transform,
    required Rect caretRect,
    required Rect composingRect,
  }) {
    _textInput.updateGeometry(
      editableSize: editableSize,
      transform: transform,
      caretRect: caretRect,
      composingRect: composingRect,
    );
  }

  @override
  void write(Uint8List data) => terminal.write(data);

  void _applyModes() {
    for (final entry in _config.modes.entries) {
      terminal.modeSet(entry.key, value: entry.value);
    }
  }

  void _applyTerminalOptions() {
    terminal.kittyImageStorageLimit = _config.kittyImageStorageLimit;
    terminal.setApcBufferLimit(_config.apcBufferLimit);
  }

  bool _consumeCommittedCompositionEditKey(
    vt.Key key,
    KeyAction action,
    Mods mods,
  ) {
    // A plain deletion immediately after a desktop candidate commit belongs
    // to the platform IME first. Modified deletions stay terminal-only so
    // protocol modes and shell shortcuts keep their encoded semantics.
    if (!_isDesktopPlatform) return false;
    if (action != .press && action != .repeat) return false;
    if (key != .backspace && key != .delete) return false;
    if (!mods.isEmpty) return false;
    return _textInput.consumeCommittedCompositionEdit();
  }

  Mods _currentMods() {
    var mods = _virtualMods;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) mods = mods | const .shift();
    if (keyboard.isControlPressed) mods = mods | const .ctrl();
    if (keyboard.isAltPressed) mods = mods | const .alt();
    if (keyboard.isMetaPressed) mods = mods | const .superKey();
    return mods;
  }

  Mods _consumedModsFor(
    String? character, {
    required int unshiftedCodepoint,
    required Mods mods,
  }) {
    // Flutter does not expose consumed modifiers, so this fallback only
    // accounts for Shift producing a different single-codepoint character.
    if (!mods.hasShift || character == null || unshiftedCodepoint == 0) {
      return const .none();
    }

    final codepoints = character.runes.iterator;
    if (!codepoints.moveNext()) return const .none();
    final codepoint = codepoints.current;
    if (codepoints.moveNext()) return const .none();
    if (codepoint == unshiftedCodepoint) return const .none();
    return const .shift();
  }

  bool _emitKeyPress(
    vt.Key key, {
    Mods mods = const .none(),
    bool clearMods = true,
  }) {
    final codepoint = unshiftedCodepointForKey(key);
    _keyEvent
      ..key = key
      ..mods = mods
      ..action = .press
      ..consumedMods = const .none()
      ..unshiftedCodepoint = codepoint
      ..utf8 = codepoint > 0 ? String.fromCharCode(codepoint) : null
      ..composing = false;

    _keyEncoder.sync(terminal);
    final result = _keyEncoder.encode(_keyEvent);
    if (result.isEmpty) return false;

    _emitOutput(utf8.encode(result));
    if (clearMods) clearVirtualMods();
    return true;
  }

  void _emitOutput(Uint8List bytes) => onOutput?.call(bytes);

  bool _extendSelection(LogicalKeyboardKey arrowKey) {
    final (dRow, dCol) = switch (arrowKey) {
      .arrowRight => (0, 1),
      .arrowLeft => (0, -1),
      .arrowUp => (-1, 0),
      .arrowDown => (1, 0),
      _ => (0, 0),
    };
    if (dRow == 0 && dCol == 0) return false;
    _renderState.update(terminal);
    selection = _selection!.moveEnd(
      dRow,
      dCol,
      totalCols: _renderState.cols,
      totalRows: totalRows,
    );
    return true;
  }

  void _handleDelete(int count) {
    if (count <= 0) return;

    var emitted = false;
    for (var i = 0; i < count; i++) {
      emitted =
          _emitKeyPress(.backspace, mods: _currentMods(), clearMods: false) ||
          emitted;
    }
    if (!emitted) return;

    clearVirtualMods();
    _onTextInput();
  }

  void _handleNewline() {
    _emitOutput(_crBytes);
    clearVirtualMods();
    _onTextInput();
  }

  void _handlePreeditChanged(String text) {
    if (_preeditText == text) return;
    _preeditText = text;
    if (text.isNotEmpty) _onTextInput();
    notifyListeners();
  }

  TerminalSizeInfo _handleSizeQuery() {
    _renderState.update(terminal);
    return TerminalSizeInfo(
      rows: _renderState.rows,
      columns: _renderState.cols,
      cellWidth: (_lastMetrics.cellWidth * _lastDevicePixelRatio).round(),
      cellHeight: (_lastMetrics.cellHeight * _lastDevicePixelRatio).round(),
    );
  }

  void _handleTextCommitted(String text) {
    if (_virtualMods.isEmpty) {
      _emitOutput(utf8.encode(text));
      _onTextInput();
      return;
    }

    if (text.length == 1) {
      final key = keyFromCodepoint(text.codeUnitAt(0));
      if (key != null) {
        sendKey(key);
        return;
      }
    }

    _emitOutput(utf8.encode(text));
    clearVirtualMods();
    _onTextInput();
  }

  void _onFocusChanged() {
    final focused = _focusNode?.hasFocus ?? false;
    if (focused == _wasFocused) return;
    _wasFocused = focused;

    if (focused && _keyboardState == .showing) {
      _textInput.show();
    } else if (focused && _keyboardState != .disabled) {
      _textInput.ensureAttached(keyboardAppearance: _brightness);
    } else if (!focused) {
      if (_keyboardState == .showing) _keyboardState = .hidden;
      _textInput.hide();
    }

    if (!focused) clearVirtualMods();

    if (terminal.modeGet(const TerminalMode.focusEvent())) {
      final event = focused ? FocusEvent.gained : FocusEvent.lost;
      _emitOutput(utf8.encode(event.encode()));
    }

    notifyListeners();
  }

  void _onTerminalChanged() {
    var changed = false;

    final newMouseTracking = terminal.mouseTracking;
    if (newMouseTracking != _mouseTracking) {
      _mouseTracking = newMouseTracking;
      changed = true;
    }

    final newActiveScreen = terminal.activeScreen;
    var leftAlternateScreen = false;
    if (newActiveScreen != _activeScreen) {
      leftAlternateScreen =
          _activeScreen == .alternate && newActiveScreen == .primary;
      _activeScreen = newActiveScreen;
      if (newActiveScreen == .primary) _applyModes();
      changed = true;
    }

    final newCursorKeyApp = terminal.modeGet(const .cursorKeys());
    if (newCursorKeyApp != _cursorKeyApplication) {
      _cursorKeyApplication = newCursorKeyApp;
      changed = true;
    }

    final newCursorBlinking =
        _config.cursorBlink ?? terminal.modeGet(const .cursorBlinking());
    if (newCursorBlinking != _cursorBlinking) {
      _cursorBlinking = newCursorBlinking;
      changed = true;
    }

    _scrollToBottomOnOutput();
    // #767: a notify means the cells may have changed (output streamed) or the
    // viewport scrolled; re-scan registered structured-text patterns on a
    // debounce so the highlights track new content. No-op when none registered.
    _scheduleDetectionRescan();
    // #824: returning to the shell (alternate->primary) must resume detection
    // immediately, not on the next stray notify — re-scan synchronously so the
    // shell's URLs/paths re-anchor the moment vim exits.
    if (leftAlternateScreen) _rescanDetections();
    if (changed) notifyListeners();
  }

  void _onTextInput() {
    if (_config.selectionClearOnTyping) clearSelection();
    _scrollToBottomOnInput();
  }

  void _scrollToBottomOnInput() {
    if (_activeScreen == .alternate) return;
    final policy = _config.scrollToBottom;
    if (policy == .onKeystroke || policy == .both) scrollToBottom();
  }

  void _scrollToBottomOnOutput() {
    if (_activeScreen == .alternate) return;
    final policy = _config.scrollToBottom;
    if (policy == .onOutput || policy == .both) scrollToBottom();
  }

  bool _shouldRouteKeyThroughTextInput({
    required KeyAction action,
    required String? character,
    required String encoded,
    required Mods mods,
  }) {
    // Desktop printable keys are offered to Flutter text input only when the
    // terminal encoder produced the same literal character. Any protocol,
    // modifier, or composition-sensitive key stays on the terminal path.
    if (encoded != character) return false;
    if (_hasActiveComposition || !_textInput.isAttached) return false;
    if (!_isDesktopPlatform) return false;
    if (action != .press && action != .repeat) return false;
    if (!_virtualMods.isEmpty) return false;
    return !mods.hasCtrl && !mods.hasAlt && !mods.hasSuper;
  }

  Future<void> _updateKeyboardState(KeyboardState newState) async {
    if (newState == _keyboardState) return;
    _keyboardState = newState;

    switch (newState) {
      case .showing when hasFocus:
        _focusNode?.requestFocus();
        _textInput.show();
      case .showing:
        _focusNode?.requestFocus();
      case .hidden when hasFocus:
        _textInput.hide();
        _textInput.ensureAttached(keyboardAppearance: _brightness);
      case .hidden:
        _textInput.hide();
      case .disabled:
        _textInput.hide();
    }

    notifyListeners();
  }

  void _wireTerminalCallbacks() {
    terminal.onWritePty = _emitOutput;
    terminal.onBell = () => onBell?.call();
    terminal.onTitleChanged = () => onTitleChanged?.call();
    terminal.onColorScheme = () => _brightness == .light ? .light : .dark;
    terminal.onSize = _handleSizeQuery;
    terminal.onDeviceAttributes = () => _config.deviceAttributes;
    final enquiry = _config.enquiryResponse;
    terminal.onEnquiry = enquiry.isEmpty
        ? null
        : () => .fromList(utf8.encode(enquiry));
  }

  /// Filters out control characters and macOS function key private-use
  /// codepoints that should not be sent as UTF-8 text to the key encoder.
  static String? _encoderCharacter(String? character) {
    if (character == null || character.isEmpty) return null;
    final code = character.codeUnitAt(0);
    if (code < _space || code == _del) return null;
    if (code >= _macFunctionKeyStart && code <= _macFunctionKeyEnd) return null;
    return character;
  }
}

/// #805: a tiny [ChangeNotifier] whose `notify()` is callable from the
/// controller, used as the narrow "decoration inputs changed" signal a
/// widget-layer decorator listens to instead of the controller's general
/// per-redraw notify. (The base [ChangeNotifier.notifyListeners] is protected,
/// so this exposes a public trigger.)
class _DecorationNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// #767: a [CellReader] over a [Terminal]'s ABSOLUTE screen rows, for the
/// structured-text re-scan.
///
/// Reads cells via `GridRef.at(terminal, ..., pointTag: PointTag.screen)`,
/// where screen row 0 is the OLDEST scrollback line — exactly the absolute,
/// top-anchored frame [HighlightRange]/[TerminalSelection] use, so the scanner
/// emits ranges already in that frame. The native handle is short-lived: each
/// [cellContent]/[rowWrap] resolves a fresh [GridRef] and disposes it
/// immediately (a `GridRef` is only valid until the next terminal operation).
/// Local row `r` maps to absolute screen row `startAbsRow + r`; [baseAbsRow]
/// reports that base so a fresh scan after eviction emits corrected rows.
class _ScreenCellReader implements CellReader {
  _ScreenCellReader({
    required this.terminal,
    required this.cols,
    required int startAbsRow,
    required int endAbsRow,
  }) : _startAbsRow = startAbsRow,
       rows = (endAbsRow - startAbsRow) < 0 ? 0 : endAbsRow - startAbsRow;

  final Terminal terminal;
  final int _startAbsRow;

  @override
  final int cols;

  @override
  final int rows;

  @override
  int get baseAbsRow => _startAbsRow;

  @override
  String cellContent(int row, int col) {
    final absRow = _startAbsRow + row;
    GridRef? ref;
    try {
      ref = GridRef.at(
        terminal,
        col: col,
        row: absRow,
        pointTag: PointTag.screen,
      );
      // A wide-character spacer tail carries no text of its own; the head cell
      // holds the glyph. Treat the tail as blank so columns stay aligned.
      if (ref.wide == CellWidth.spacerTail) return '';
      return ref.content;
    } catch (_) {
      return '';
    } finally {
      ref?.dispose();
    }
  }

  @override
  bool rowWrap(int row) {
    final absRow = _startAbsRow + row;
    GridRef? ref;
    try {
      ref = GridRef.at(
        terminal,
        col: 0,
        row: absRow,
        pointTag: PointTag.screen,
      );
      return ref.rowWrap;
    } catch (_) {
      return false;
    } finally {
      ref?.dispose();
    }
  }

  @override
  String? hyperlinkAt(int row, int col) {
    final absRow = _startAbsRow + row;
    GridRef? ref;
    try {
      ref = GridRef.at(
        terminal,
        col: col,
        row: absRow,
        pointTag: PointTag.screen,
      );
      // libghostty attaches the FULL OSC-8 URI to every cell of the link
      // (including wrapped continuation rows), so reading it per-cell yields the
      // exact link that spans all wrapped rows by construction (#767 Slice B).
      return ref.hyperlinkUri;
    } catch (_) {
      return null;
    } finally {
      ref?.dispose();
    }
  }
}
