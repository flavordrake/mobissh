import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
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
  // PAINT-STALENESS ROOT FIX (2026-07-08T00-51-01 "paint not happening", saga
  // #887/#898/#900/#918/#921/#922/#931): this controller used to own its own
  // `RenderState` and call `update(terminal)` before every dimension read
  // (visibleRowsText, anchor geometry, the #873 prune, the #767 rescan, …).
  // libghostty's `RenderState.update` CONSUMES the terminal's per-row damage,
  // and — proven by test/terminal/render_state_foreign_consume_test.dart — a
  // handle whose update runs AFTER another handle consumed that damage keeps
  // serving its OLD row content even while reporting a non-clean DirtyState.
  // So with detection active and ANY anchor live (e.g. a URL sitting on
  // screen), the synchronous every-notify prune consumed the damage FIRST and
  // the render box's paint-time sync rebuilt the full grid from a STALE
  // snapshot: telemetry said `sync rebuilt=34` while the glass stayed frozen.
  //
  // The cure: the controller performs NO RenderState updates at all. Every
  // former render-state cols/rows read comes from [_gridCols]/[_gridRows] —
  // seeded from the config and updated by [handleResize], the single seam
  // through which the render box resizes the terminal — and all CONTENT reads
  // already went through live `GridRef`/`Formatter` queries, which do not
  // consume damage. The render box's frame builder is now the ONLY RenderState
  // consumer of this terminal, restoring libghostty's single-consumer contract.
  int _gridCols;
  int _gridRows;
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

  /// #1044: CEILING on [_scrollSettleTimer]. A line repainting IN PLACE while
  /// the viewport bottom-follows re-arms the settle timer on every frame (the
  /// painted offset jitters by a row as the follow re-pins), so a pure trailing
  /// settle holds [_isScrolling] TRUE for the whole repaint burst — and
  /// [_rescanDetections] defers EVERY scan at the scroll gate, so the churning
  /// line never anchors (the on-emulator #1044 failure a detection-debounce
  /// ceiling alone does NOT cover, because the defer is at the settle gate).
  /// This ceiling forces a QUIESCE reconcile after this long of unbroken
  /// scroll-churn — but ONLY when [_contentDirty] shows the grid was actually
  /// rewritten (content waiting to be scanned). A real user fling (no new
  /// content) is untouched: the drag-gate's "zero scans while flinging"
  /// invariant holds. Armed once per scrolling episode (`??=`), re-armed for
  /// the next window on fire. Cancelled on dispose / real settle.
  Timer? _scrollSettleMaxWait;

  /// #1044: how long of CONTINUOUS scroll-churn (offset never holding still)
  /// forces one quiesce reconcile via [_scrollSettleMaxWait]. Bounded so a
  /// perpetually-repainting bottom-following line still scans periodically.
  static const int _scrollSettleMaxWaitMs = 300;

  /// #805: fires ONLY when a widget-layer decorator's inputs change — the
  /// detected [_detectionMatches] set (after a settled re-scan) or the
  /// [_paintedViewportOffset] (after a frame paints a new offset). A decorator
  /// layer listens to THIS instead of the controller's general notify, so it
  /// re-resolves anchor rects only when the decoration geometry actually moves,
  /// not on every one of the ~15 redraw notifies/sec a streaming TUI scroll
  /// emits. Exposed via [decorationListenable].
  final _DecorationNotifier _decorationNotifier = _DecorationNotifier();

  /// #887: set while a [_onTerminalChanged] notify that arrived MID-FRAME has
  /// already scheduled its deferred side-effects to the next post-frame
  /// callback. libghostty's [Terminal.resize] — invoked synchronously from
  /// [TerminalRenderBox.performLayout] when the grid is re-sized (SFTP browser
  /// opens, keyboard inset changes the layout) — fires the terminal listener
  /// DURING the layout/paint phase. Running the prune's `highlights=` notify
  /// (→ the widget's `_updateTextInputGeometry` reading `RenderBox.size`) or
  /// `_decorationNotifier.notify()` (→ an `AnimatedBuilder`/`setState`) then is
  /// illegal ("RenderBox.size accessed beyond the scope…" / "Build scheduled
  /// during frame"). When mid-frame we DEFER those effects to the next
  /// post-frame callback; this flag coalesces a burst of mid-frame notifies in
  /// the same frame into a single deferral. The normal (non-layout) notify path
  /// stays synchronous so #873 eviction remains immediate when it is safe.
  bool _deferredFrameWorkScheduled = false;

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

  /// #1045: the per-match style resolver the detection bake routes through
  /// (see [TerminalController.detectionHighlightStyleOf]).
  HighlightStyle? Function(StructuredMatch match)? _detectionHighlightStyleOf;

  /// #767: debounce for the cell re-scan. The terminal notifies on every output
  /// write AND every scroll; coalesce a burst into one scan so streaming output
  /// doesn't re-scan every byte. Cancelled on dispose.
  Timer? _detectionDebounce;

  /// #1044: MAX-WAIT ceiling for the [_detectionDebounce]. A region that
  /// repaints IN PLACE faster than [_detectionDebounceMs] — a progress bar,
  /// spinner, clock, or a repainting-TUI status line (the owner's Claude-Code
  /// TUI) — re-arms the trailing debounce on EVERY notify, so a pure trailing
  /// debounce fires NEVER and the churning line never anchors (the on-emulator
  /// #1044 acceptance failure: "the repainted line never anchored"). This
  /// single ceiling timer is armed at the START of a churn chain and is NOT
  /// pushed out by later notifies (`??=`), so it forces ONE reconcile after
  /// [_detectionMaxWaitMs] of unbroken churn; [_fireDetectionRescan] then
  /// clears it so the next quiet gap re-arms a fresh chain. This is the
  /// content-update settle path — SEPARATE from the scroll drag-gate (which
  /// suppresses all scan work during an active fling, [_rescanDetections]).
  /// Cancelled on dispose / clear.
  Timer? _detectionMaxWait;

  /// #767: how many scrollback rows ABOVE the active viewport the re-scan reads.
  /// Bounded so detection never walks unbounded history on every notify — only
  /// the active screen plus this many recent scrollback rows are scanned, which
  /// covers a URL the user just scrolled near without an O(scrollback) cost.
  static const int _detectionScrollbackWindow = 200;

  /// #767: debounce window (ms) for the cell re-scan. Mirrors the app's old
  /// 120ms URL re-detect debounce, now owned by the controller.
  static const int _detectionDebounceMs = 120;

  /// #1044: force a reconcile scan after this long of CONTINUOUS sub-debounce
  /// churn even if the content never "settles" (see [_detectionMaxWait]).
  /// Bounded so a perpetually-repainting region still scans PERIODICALLY —
  /// detections stay live on a live-updating line — without paying a full scan
  /// on every sub-interval notify. Comfortably above [_detectionDebounceMs] so
  /// a normal streaming burst still coalesces on the trailing edge; the ceiling
  /// only bites when the trailing edge can never be reached.
  static const int _detectionMaxWaitMs = 300;

  /// #883: the COORDINATE-FRAME EPOCH of [_detectionMatches] — the
  /// scrollbackRows/cols/visibleRows observed when the matches' absolute rows
  /// were last anchored (a successful [_rescanDetections]) or fully
  /// re-validated ([_pruneStaleDetections] confirming every match in place).
  ///
  /// Absolute `screen` rows are APPEND-STABLE: new output never moves stored
  /// coordinates while scrollback grows below its cap. They are invalidated
  /// wholesale only when the frame itself moves: a scrollback PAGE EVICTION at
  /// the cap (libghostty evicts in large page bursts — observed ≈1139 rows at
  /// once at cols=40 — visible as scrollbackRows SHRINKING), an `ESC[3J`
  /// scrollback clear (also a shrink), or a resize REFLOW (cols/rows change).
  /// The prune compares the live frame against this epoch to tell "the cells
  /// under this match really changed" (evict, #873) from "the coordinates
  /// drifted out from under a live match" (keep/re-locate, #883).
  int _detectionFrameScrollback = 0;
  int _detectionFrameCols = 0;
  int _detectionFrameRows = 0;

  /// #883: row slack when re-locating a match after an observed scrollback
  /// shrink. The observable drop (epoch − current scrollbackRows) undershoots
  /// the true shift by however many rows were APPENDED in the same burst, so a
  /// little slack catches small same-burst appends; larger bursts simply defer
  /// to the debounced rescan.
  static const int _relocateRowSlack = 4;

  /// #1044: detection hot-path counters (see [DetectionScanStats]).
  final DetectionScanStats _detectionStats = DetectionScanStats();

  /// #1044: the CONTENT-KEYED SCAN CACHE — the absolute-row range
  /// `[_scannedLo, _scannedHi)` whose detection results ([_detectionMatches]
  /// restricted to those rows) are CURRENT. The key invariant that makes a
  /// row cache possible without consuming libghostty damage (which is single-
  /// consumption and owned by the paint snapshot — reference_paint_root_985):
  /// scrollback rows are IMMUTABLE in place. VT writes only address the
  /// active grid; absolute `screen` rows are append-stable (#883), and the
  /// whole frame is invalidated wholesale on the shifts the epoch below
  /// tracks. So a covered row above the grid cannot have changed since it
  /// was scanned, and a rescan only needs to read (a) rows newly entering
  /// the window and (b) the MUTABLE suffix (every row that has been part of
  /// the active grid since the last completed scan — [_scannedGridLo]).
  /// `-1` = no valid cache (full-window scan on next pass).
  int _scannedLo = -1;
  int _scannedHi = -1;

  /// #1044: `terminal.scrollbackRows` at the last COMPLETED scan — the first
  /// row that has been part of the (mutable) active grid since then. On a
  /// dirty rescan the cache is trimmed to the clean prefix `[.., this)` and
  /// the suffix re-read.
  int _scannedGridLo = 0;

  /// #1044: the cache's own coordinate-frame epoch (scrollback shrink /
  /// resize / screen flip / pattern-suppression flip all invalidate). Kept
  /// SEPARATE from the #883 `_detectionFrame*` epoch: the prune ADVANCES that
  /// one on full confirmation, which must not launder a cache staleness.
  int _scannedScrollback = 0;
  int _scannedCols = 0;
  int _scannedRows = 0;
  TerminalScreen _scannedScreen = .primary;
  bool _scannedSuppressHeuristics = false;

  /// #1044: a terminal content notify arrived since the last completed scan —
  /// the active grid may have been rewritten in place, so the mutable suffix
  /// must be re-read on the next rescan. Scroll notifies never set this
  /// (viewport movement cannot change cell content).
  bool _contentDirty = false;

  /// #1044: a rescan fired while [_isScrolling]; run ONE reconcile on the
  /// settle edge instead of competing with fling frames for FFI/regex time.
  bool _rescanPendingSettle = false;

  /// #1044: how many rows of scanned coverage to RETAIN around the viewport.
  /// Scrolling through a long buffer accumulates coverage (and its matches);
  /// beyond this the far end is trimmed and re-scanned on return. Generous —
  /// match storage is cheap; re-scanning is the expensive part.
  static const int _detectionCacheRetentionRows = 2000;

  /// #1044: fixed row slack added around a partial scan region before the
  /// wrap-flag extension, so the #1042 command IN-BLOCK continuation join
  /// (which joins across NON-wrapped rows) sees its block context. A block
  /// deeper than this may join differently at a region edge than a full scan
  /// would — accepted; the next full-window scan (frame shift) reconverges.
  static const int _detectionRegionJoinSlack = 12;

  /// #1044: hard cap on the wrap-flag region extension (defensive — a
  /// pathological all-wrapped buffer must not turn a partial scan into an
  /// unbounded walk).
  static const int _detectionRegionWrapCap = 200;

  /// #1046: MISS-GRACE timers, one per anchor whose payload is currently
  /// unaccounted for on the grid. An in-place TUI repaint routinely leaves a
  /// notify observable BETWEEN a row's erase and its redraw (the owner trace
  /// shows the payload back at every chunk boundary while the anchor
  /// blinked), and a moved line can be off-grid for one whole chunk. A
  /// missed anchor is therefore KEPT and retried (validate/relocate on each
  /// subsequent notify); only when the payload stays gone for
  /// [_detectionMissGraceMs] does the timer evict it. Keyed by match
  /// INSTANCE (StructuredMatch has identity equality). Timers are cancelled
  /// when the match re-validates, relocates, is replaced by an equal fresh
  /// match, or the controller is disposed / patterns cleared.
  final Map<StructuredMatch, Timer> _detectionMissTimers =
      <StructuredMatch, Timer>{};

  /// #1046: how long a missed SPAN anchor survives while its payload is
  /// unaccounted for. Long enough to ride a mid-chunk erase→redraw and a
  /// one-chunk absence (~230ms observed in the owner trace), short enough
  /// that a genuinely rewritten row sheds its orphaned WASH well inside the
  /// #873 comfort band.
  static const int _detectionMissGraceMs = 350;

  /// #1046: the BLOCK-tier (command) grace. A wrapped command's assembled
  /// logical line mutates through a TUI redraw (the continuation row lands a
  /// chunk later → the scorer sees a truncated body → a DIFFERENT payload),
  /// so the exact-payload relocate can miss for most of a redraw burst
  /// (~1.0s observed in the owner trace). A block anchor paints NO wash —
  /// its only affordance is the gutter chip — so the longer afterlife has no
  /// stale-highlight cost, and it is what keeps the chip from blinking at
  /// every repaint (#1046's owner report WAS a command chip).
  static const int _detectionMissGraceBlockMs = 1500;

  TerminalControllerImpl({TerminalConfig config = const TerminalConfig()})
    : _config = config,
      _gridCols = config.cols,
      _gridRows = config.rows,
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
    // #863: map the VIEWPORT row to absolute via the PAINTED offset — the SAME
    // offset the highlight PAINT geometry uses ([anchorRects]/
    // [AnchorGeometry.rectsFor]: `viewRow = absRow - _paintedViewportOffset`).
    // Hit-testing against the LIVE `scrollbar.offset` (which can run a frame
    // ahead of the painted glyphs during a tmux-redraw scroll, #803) maps the
    // tapped row to a DIFFERENT absolute row than the one drawn → the tap lands
    // off the highlight. Resolving both against [_paintedViewportOffset] keeps
    // paint and hit-test on ONE geometry source so they cannot diverge.
    // #958: on the ALT screen that offset is the screen-space viewport top.
    final absRow = row + screenViewportTop;
    HighlightRange? match;
    for (final range in _highlights) {
      if (range.contains(absRow, col)) match = range;
    }
    return match;
  }

  @override
  HighlightStyle? Function(StructuredMatch match)?
      get detectionHighlightStyleOf => _detectionHighlightStyleOf;

  @override
  set detectionHighlightStyleOf(
      HighlightStyle? Function(StructuredMatch match)? value) {
    _detectionHighlightStyleOf = value;
  }

  @override
  void restyleDetectionHighlights() {
    if (_detectionMatches.isEmpty) return;
    final next = _styledHighlights(_detectionMatches);
    // Equality-gated so opportunistic callers (every build) never churn
    // listeners; the setter's `identical` check would notify on a fresh but
    // equal list.
    if (next.length == _highlights.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != _highlights[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    highlights = next;
  }

  /// #1045: bake [matches] into paintable [HighlightRange]s. With no resolver
  /// installed this is the pre-#1045 bake (the ranges carry their pattern's
  /// static style). With [_detectionHighlightStyleOf] set, each match resolves
  /// per ANCHOR: null suppresses it (paints nothing — the anchor itself stays
  /// hit-testable via [_detectionMatches]); a style is stamped onto all its
  /// ranges with capsule caps on the true first/last range. Defensive: an
  /// app-side resolver throw suppresses that match rather than crashing the
  /// scan path (a PTY byte must never take the session down).
  List<HighlightRange> _styledHighlights(List<StructuredMatch> matches) {
    final resolver = _detectionHighlightStyleOf;
    if (resolver == null) return [for (final m in matches) ...m.ranges];
    final out = <HighlightRange>[];
    for (final m in matches) {
      HighlightStyle? style;
      try {
        style = resolver(m);
      } catch (_) {
        style = null;
      }
      if (style == null) continue;
      final ranges = m.ranges;
      for (var i = 0; i < ranges.length; i++) {
        final r = ranges[i];
        out.add(HighlightRange(
          startRow: r.startRow,
          startCol: r.startCol,
          endRow: r.endRow,
          endCol: r.endCol,
          background: style.background,
          underline: style.underline,
          payload: r.payload,
          capsule: style.capsule,
          capsuleStart: style.capsule && i == 0,
          capsuleEnd: style.capsule && i == ranges.length - 1,
        ));
      }
    }
    return out;
  }

  @override
  void registerTextPattern(TextPattern pattern) {
    _textPatterns[pattern.id] = pattern;
    // #1044: the pattern SET changed — cached per-row results were computed
    // with the old set and cannot be trusted.
    _invalidateDetectionScanCache();
    // Scan synchronously so a freshly-registered pattern highlights any URLs
    // already on screen without waiting for the next output/scroll notify.
    _rescanDetections();
  }

  @override
  void clearTextPatterns() {
    if (_textPatterns.isEmpty && _detectionMatches.isEmpty) return;
    _textPatterns.clear();
    _detectionDebounce?.cancel();
    _detectionMaxWait?.cancel();
    _detectionMaxWait = null;
    _cancelAllMissGrace();
    _invalidateDetectionScanCache();
    _detectionMatches = const [];
    // Clear only the detection-driven highlights (which are the only writer of
    // _highlights once a pattern is registered).
    highlights = const [];
  }

  @override
  StructuredMatch? matchAt(
      {required int row, required int col, TextTier? tier}) {
    if (_detectionMatches.isEmpty) return null;
    // #863: UNIFY hit-test with paint. The widget-layer URL bubble PAINTS its
    // anchor rects via [anchorRects] -> [AnchorGeometry.rectsFor], which resolves
    // a viewport row from the PAINTED offset (`viewRow = absRow -
    // _paintedViewportOffset`). The tap router maps the tapped pixel to a
    // viewport `row` and calls this; if we mapped it to absolute via the LIVE
    // `scrollbar.offset` instead (which can lead the painted glyphs by a frame
    // during a tmux-redraw scroll, #803), the tappable cell would sit a row off
    // the painted bubble — the #863 "tap selects instead of copying" + the
    // off-by-1 highlight. Mapping via [_paintedViewportOffset] makes the tap
    // consume the EXACT offset the bubble was painted with, so a tap anywhere on
    // the painted URL (incl. a :port URL or a wrapped multi-row URL) resolves to
    // its match. They share ONE geometry source and cannot diverge.
    // #958: on the ALT screen that offset is the screen-space viewport top.
    final absRow = row + screenViewportTop;
    final snappedCol = terminal.snapColToWideBoundary(
      row,
      col,
      inclusive: true,
      cols: _gridCols,
      rows: _gridRows,
    );
    // #998 A: resolve per TIER — a cell covered by both a span match and its
    // containing block match answers with the SPAN (innermost) match, so an
    // inline tap on a URL inside a command never routes to the command block.
    // [tier] scopes the query (the block match stays resolvable). Within a
    // tier the last detected containing match wins, as before.
    StructuredMatch? span;
    StructuredMatch? block;
    for (final m in _detectionMatches) {
      if (!m.contains(absRow, snappedCol)) continue;
      if (m.tier == TextTier.block) {
        block = m;
      } else {
        span = m;
      }
    }
    if (tier == TextTier.span) return span;
    if (tier == TextTier.block) return block;
    return span ?? block;
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
  DetectionScanStats get detectionScanStats => _detectionStats;

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
    // #1044: arm the settle CEILING once at the start of a scrolling episode
    // and do NOT push it out on later offset changes (`??=`). Continuous
    // scroll-churn (a bottom-following repainting line) keeps re-arming the
    // trailing settle above, so without this it would never fire and every
    // content rescan would defer forever; the ceiling forces one quiesce
    // reconcile after [_scrollSettleMaxWaitMs] — but only when content is
    // actually pending (see [_onScrollSettledMaxWait]).
    _scrollSettleMaxWait ??= Timer(
      const Duration(milliseconds: _scrollSettleMaxWaitMs),
      _onScrollSettledMaxWait,
    );
  }

  /// #1044: the settle-ceiling target. Forces ONE quiesce reconcile when
  /// continuous scroll-churn has starved the trailing [_scrollSettleTimer]
  /// past [_scrollSettleMaxWaitMs] AND [_contentDirty] shows the grid was
  /// actually rewritten (a bottom-following repaint). A pure user fling never
  /// sets [_contentDirty], so it is left scrolling with zero scan work — the
  /// drag-gate invariant. This does NOT
  /// leave the scrolling state (the offset is still moving, the decorator stays
  /// hidden); it only unblocks DETECTION so a perpetually-repainting line
  /// anchors and keeps scanning periodically. The next genuine settle still
  /// runs [_onScrollSettled] normally.
  void _onScrollSettledMaxWait() {
    _scrollSettleMaxWait = null;
    if (_disposed || !_isScrolling) return;
    // The trigger is [_contentDirty] ALONE — the active grid was rewritten
    // since the last scan (a bottom-following repaint). A PURE fling never sets
    // it (scroll notifies don't; that is the basis of "pure scroll = 0 scans"),
    // so a real fling is left scrolling with zero scan work — drag-gate intact.
    // NOT [_rescanPendingSettle]: that flag is set whenever a debounce happens
    // to fire mid-fling and defer at the scroll gate (discovery-only, no content
    // change), so forcing on it would scan during a legitimate fling (#1044
    // regression: it broke the pure-fling zero-passes invariant).
    if (_contentDirty) {
      _rescanPendingSettle = false;
      // Bypass the scroll gate for this ONE forced reconcile — the whole point
      // is to scan despite _isScrolling, because the "scroll" is really content
      // churn that will never settle on its own.
      _rescanDetections(bypassScrollGate: true);
    }
    // Re-arm for the next ceiling window so an unbroken churn keeps getting a
    // periodic scan (and a still-live fling gets re-evaluated next window).
    if (_isScrolling) {
      _scrollSettleMaxWait = Timer(
        const Duration(milliseconds: _scrollSettleMaxWaitMs),
        _onScrollSettledMaxWait,
      );
    }
  }

  /// #812: trailing edge — the painted offset has held still for [_scrollSettleMs].
  /// Leave the scrolling state and wake the decoration listener ONCE so the
  /// decorator rebuilds and SHOWS, re-resolving anchor rects at the now-stable
  /// painted offset (painted == live → exact placement, no drift).
  void _onScrollSettled() {
    _scrollSettleTimer = null;
    // #1044: a genuine settle supersedes the ceiling — cancel it so it does not
    // fire a redundant reconcile after the offset has already come to rest.
    _scrollSettleMaxWait?.cancel();
    _scrollSettleMaxWait = null;
    if (_disposed || !_isScrolling) return;
    _isScrolling = false;
    // #1044: the QUIESCE reconcile — any rescan that fired mid-scroll was
    // deferred; run exactly one now that the offset is stable, so newly-
    // revealed rows are scanned (cache-partial) and anchors appear. This is
    // the debounced settle pass the #918 settle-tick precedent describes.
    if (_rescanPendingSettle) {
      _rescanPendingSettle = false;
      _rescanDetections();
    }
    _decorationNotifier.notify();
  }

  @override
  List<Rect> anchorRects(HighlightRange range) {
    final metrics = _lastMetrics;
    if (metrics.cellWidth <= 0 || metrics.cellHeight <= 0) return const [];
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
    // #958: on the ALT screen the offset is the screen-space viewport top.
    return AnchorGeometry.rectsFor(
      range,
      metrics: metrics,
      viewportOffset: screenViewportTop,
      cols: _gridCols,
      viewportRows: _gridRows,
      origin: Offset(_lastPadding.left, _lastPadding.top),
    );
  }

  /// #958: the top visible row expressed in the SCREEN coordinate space the
  /// scanner anchors in (`PointTag.screen`, row 0 = the oldest PRIMARY-screen
  /// scrollback line; the ALTERNATE screen's rows sit AFTER that history).
  ///
  /// On the PRIMARY screen the painted viewport offset already IS that value
  /// (frame-synced scrollback offset, #803/#863). On the ALTERNATE screen the
  /// scrollbar/painted offset are ALT-LOCAL (always 0 — the alt screen has no
  /// scrollback), while anchors carry `scrollbackRows + altRow`. Subtracting the
  /// alt-local 0 put every anchor "below" the viewport → `anchorGutterRow`
  /// returned null for ALL anchors → NO gutter marks in tmux, ever (the #958
  /// device symptom; reproduced by golden_flow_tui_test: anchors at rows 46/56
  /// vs viewportRows=44, offset=0). The alt viewport's top in screen space is
  /// the history length itself.
  @override
  int get screenViewportTop => _activeScreen == .alternate
      ? terminal.scrollbackRows
      : _paintedViewportOffset;

  @override
  int? anchorGutterRow(HighlightRange range) {
    // #955: resolve against the PAINTED viewport offset — the SAME frame snapshot
    // [anchorRects]/[matchAt] use (`viewRow = absRow - _paintedViewportOffset`),
    // NOT the live `scrollbar.offset` (which can run a frame AHEAD of the painted
    // glyphs during a tmux-redraw scroll, the #803/#863 divergence). The gutter
    // mark then moves in lockstep with the painted rows, never a frame ahead.
    // #958: on the ALT screen that offset must be the screen-space viewport top
    // (see [screenViewportTop]), not the alt-local 0.
    return AnchorGeometry.gutterRowFor(
      range,
      viewportOffset: screenViewportTop,
      viewportRows: _gridRows,
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
      _fireDetectionRescan,
    );
    // #1044: arm the max-wait ceiling at the START of a churn chain and do NOT
    // push it out on later notifies (`??=`). Continuous sub-debounce churn (a
    // repainting status line, progress bar, spinner) keeps cancelling the
    // trailing debounce above, so without this it would fire never and the
    // line would never anchor; this forces one reconcile after
    // [_detectionMaxWaitMs] regardless. [_fireDetectionRescan] clears it so a
    // quiet gap starts a fresh chain.
    _detectionMaxWait ??= Timer(
      const Duration(milliseconds: _detectionMaxWaitMs),
      _fireDetectionRescan,
    );
  }

  /// #1044: the debounce / max-wait timer target. Cancels BOTH timers (whichever
  /// did not fire) and clears the ceiling so the next notify starts a fresh
  /// churn chain, then runs the scan. Routing both timers through here keeps the
  /// trailing edge and the ceiling from double-scanning and guarantees the
  /// ceiling is re-armable.
  void _fireDetectionRescan() {
    _detectionDebounce?.cancel();
    _detectionDebounce = null;
    _detectionMaxWait?.cancel();
    _detectionMaxWait = null;
    _rescanDetections();
  }

  /// #873: SYNCHRONOUSLY re-validate the live detection anchors against the
  /// CURRENT cells and DROP any whose anchored cell-run no longer carries the
  /// matched text. Runs on every redraw notify ([_onTerminalChanged]), BEFORE the
  /// debounced full [_rescanDetections] would fire.
  ///
  /// The full re-scan is DEBOUNCED (~120ms) and a streaming TUI keeps cancelling/
  /// pushing the timer out, so a line REDRAWN in place (tmux/app rewrites the row
  /// with different content) or SCROLLED past the bounded window left the old
  /// [StructuredMatch] in [_detectionMatches] — and thus in [anchors]/[matchAt] —
  /// for the whole debounce window (often far longer under streaming output). The
  /// widget-layer decorator paints those stale anchors over text that no longer
  /// contains the match: the "orphaned highlight box" device report (#873).
  ///
  /// EVICTION must not wait on the debounce. This prune is the immediate
  /// counterpart to the rescan: discovery of NEW matches stays debounced (the
  /// expensive bounded-window scan), but a match whose cells CHANGED is dropped
  /// the moment the redraw is observed. It re-reads ONLY the rows each existing
  /// match occupies (cheap) and, using the SAME scanner/patterns, keeps the match
  /// only if an equivalent same-payload match still covers those cells — so wrap-
  /// join, normalize (`www.`→`https://`), and OSC-8 grouping all re-validate
  /// identically to a full scan.
  ///
  /// #883: eviction happens ONLY on a CONFIRMED content change — i.e. when the
  /// coordinate frame the stored rows were anchored in still holds (scrollback
  /// has not shrunk, no resize). When the frame has SHIFTED (a scrollback page
  /// eviction at the cap moves ALL absolute rows down in one large burst; an
  /// `ESC[3J` clear or a resize reflow invalidates them outright), a mismatch
  /// at the stored rows proves nothing: the #883 regression evicted live
  /// anchors here, killing #767's "highlight tracks scroll into scrollback".
  /// Shifted-frame matches are re-located at the drop-corrected rows (ranges
  /// updated) or kept for the debounced rescan to re-anchor from content.
  ///
  /// Defensive like [_rescanDetections]: any FFI/scan hiccup must never crash the
  /// session, so a failure leaves the existing matches untouched (the debounced
  /// full rescan will still correct them) rather than throwing.
  void _pruneStaleDetections() {
    if (_detectionMatches.isEmpty) return;
    // No patterns left (cleared) — nothing legitimately detectable; drop all.
    if (_textPatterns.isEmpty) {
      _cancelAllMissGrace();
      _detectionMatches = const [];
      highlights = const [];
      _decorationNotifier.notify();
      return;
    }
    // Mirror [_rescanDetections]'s alt-screen suppression so a prune uses the
    // SAME pattern set the (debounced) full scan would, and a regex match left
    // over from the primary screen is re-validated against the OSC-8-only set on
    // the alt screen (and thus dropped) rather than wrongly kept.
    final suppressHeuristics =
        _activeScreen == .alternate && _mouseTracking == .none;
    final scanPatterns = suppressHeuristics
        ? [for (final p in _textPatterns.values) if (p.isOsc8Source) p]
        : _textPatterns.values.toList(growable: false);

    List<StructuredMatch> survivors;
    var changed = false;
    try {
      final cols = _gridCols;
      final visibleRows = _gridRows;
      if (cols <= 0 || visibleRows <= 0) {
        // #883: a degenerate render state (mid-layout/churn) reads nothing —
        // it cannot CONFIRM a content change, so it must not evict. Leave the
        // set as-is; the debounced rescan reconciles once dims are real.
        return;
      } else {
        final scrollback = terminal.scrollbackRows;
        final maxEndAbs = scrollback + visibleRows; // exclusive buffer bound
        // #883: the stored absolute rows are only meaningful while the
        // coordinate frame they were anchored in still holds. A scrollback
        // SHRINK (page eviction at the cap, `ESC[3J` clear) shifts/erases
        // history rows; a cols/rows change reflows them. In either case a
        // mismatch at the stored rows proves NOTHING about the content, so
        // eviction must not key off it (the #883 over-evict).
        final frameShifted = scrollback < _detectionFrameScrollback ||
            cols != _detectionFrameCols ||
            visibleRows != _detectionFrameRows;
        final drop = _detectionFrameScrollback - scrollback;
        var allConfirmed = true;
        survivors = <StructuredMatch>[];
        _detectionStats.prunes++;
        // #1046: ONE shared grid scan, lazily performed on the first trusted-
        // frame miss, so a miss can be atomically RELOCATED (see below)
        // instead of evict-now / rediscover-after-the-debounce.
        List<StructuredMatch>? gridMatches;
        for (final m in _detectionMatches) {
          // #1044: a match whose rows sit fully BELOW the active grid lives
          // in immutable scrollback — VT writes only address the grid and
          // absolute rows are append-stable (#883), so in an UNSHIFTED frame
          // its cells cannot have changed. Keep it without a re-read; only
          // matches touching the grid (the in-place TUI rewrite surface #873
          // exists for) pay for a re-validation scan. (Corner: a row edited
          // in the same chunk that scrolled it out of the grid is caught by
          // the next debounced rescan's dirty suffix, not this prune.)
          if (!frameShifted && _matchBottomRow(m) < scrollback) {
            survivors.add(m);
            _detectionStats.pruneSkippedImmutable++;
            continue;
          }
          final v = _revalidatedMatch(
            m,
            scanPatterns,
            cols,
            maxEndAbs,
            frameShifted: frameShifted,
            drop: drop,
          );
          if (v == null) {
            // #1046: the rows under the anchor changed — but an in-place TUI
            // repaint (Claude-CLI etc.) MOVES lines by rewriting the whole
            // view shifted, usually within the SAME chunk. Evicting now and
            // waiting for the debounced rescan to rediscover the payload at
            // its new rows leaves a visible affordance gap — the owner's
            // flickering gutter chip (vanish→reappear windows of 0.2–1.4s in
            // the report's byte-trace, because streaming keeps pushing the
            // debounce out). Instead, RELOCATE atomically: one shared scan of
            // the active grid (where all in-place rewrites live), adopt the
            // same payload at its new rows in this same notify.
            final grid = gridMatches ??=
                _scanWindow(scrollback, maxEndAbs, cols, scanPatterns);
            final moved = _nearestRelocation(m, grid, survivors);
            if (moved != null) {
              _cancelMissGrace(m);
              survivors.add(moved);
              changed = true; // moved → ranges updated
              _detectionStats.pruneRelocated++;
              continue;
            }
            // Not on the grid at all RIGHT NOW — which, mid-repaint, often
            // means "a notify landed between the erase and the redraw of the
            // same chunk" (the #1046 trace shows the payload back on the
            // grid at every chunk BOUNDARY while the anchor blinked). Give
            // the anchor a bounded MISS GRACE instead of evicting: keep it,
            // retry validate/relocate on every subsequent notify, and evict
            // via the grace timer only if the payload stays gone. This
            // trades the #873 "evict immediately" for "evict within
            // ~[_detectionMissGraceMs]" — still far inside the multi-second
            // orphan lingering #873 was about, and it kills the blink.
            survivors.add(m);
            _armMissGrace(m);
            continue;
          }
          if (identical(v, m)) {
            _cancelMissGrace(m); // content re-confirmed at its rows
            if (frameShifted) allConfirmed = false; // kept on deferral
          } else {
            _cancelMissGrace(m);
            changed = true; // re-located → ranges updated
          }
          survivors.add(v);
        }
        // Advance the frame epoch only when every surviving match was
        // CONFIRMED at the current coordinates (trusted re-validation or a
        // successful re-locate). A deferral leaves the epoch stale so later
        // prunes keep treating the frame as shifted until the debounced
        // rescan re-anchors.
        if (allConfirmed) {
          _detectionFrameScrollback = scrollback;
          _detectionFrameCols = cols;
          _detectionFrameRows = visibleRows;
        }
      }
    } catch (_) {
      // A read hiccup must not crash or spuriously clear anchors; leave the set
      // as-is and let the debounced full rescan reconcile.
      return;
    }

    if (!changed) return; // nothing dropped or moved
    _detectionMatches = survivors;
    highlights = _styledHighlights(survivors);
    // The anchor set shrank/moved → wake the narrow decoration listener so the
    // decorator re-resolves and the orphaned box vanishes immediately.
    _decorationNotifier.notify();
  }

  /// #873/#883: re-validate [match] against the current cells and decide
  /// evict-vs-keep:
  ///
  /// - `null` — CONFIRMED gone: the coordinate frame is trusted
  ///   ([frameShifted] false: scrollback has not shrunk, no resize since the
  ///   match was anchored — absolute rows are append-stable, so the stored
  ///   rows still address the same content) and a fresh scan over exactly
  ///   those rows no longer yields a same-payload match. The row was redrawn
  ///   in place with different/erased text → evict synchronously (#873).
  /// - the SAME instance — kept: either the trusted re-scan still found the
  ///   payload at its stored rows, or the frame HAS shifted and the match
  ///   could not be cheaply re-located — then the mismatch proves nothing
  ///   (the #883 over-evict), so KEEP and defer to the debounced
  ///   [_rescanDetections], which re-anchors from content (or legitimately
  ///   drops it once it is outside the bounded window).
  /// - a NEW instance — the frame shifted but the same-payload match was
  ///   RE-LOCATED at the drop-corrected rows: keep it with the fresh
  ///   coordinates so anchors/highlights track the eviction shift
  ///   immediately instead of waiting out the debounce.
  ///
  /// Re-uses the production scanner + patterns so re-validation matches
  /// detection exactly (wrap-join, normalize, OSC-8 grouping).
  StructuredMatch? _revalidatedMatch(
    StructuredMatch match,
    List<TextPattern> scanPatterns,
    int cols,
    int maxEndAbs, {
    required bool frameShifted,
    required int drop,
  }) {
    if (scanPatterns.isEmpty) return null;
    var top = match.ranges.first.topRow;
    var bottom = match.ranges.first.bottomRow;
    for (final r in match.ranges) {
      if (r.topRow < top) top = r.topRow;
      if (r.bottomRow > bottom) bottom = r.bottomRow;
    }

    if (!frameShifted) {
      // Trusted frame — #873 semantics, unchanged: scan exactly the stored
      // rows (clamped to the live buffer). Same-payload found → keep; a
      // readable mismatch, an erased row, or rows truly beyond the live
      // buffer → confirmed content change → evict.
      final startAbs = top < 0 ? 0 : top;
      final endAbs = (bottom + 1) > maxEndAbs ? maxEndAbs : bottom + 1;
      if (endAbs - startAbs <= 0) return null;
      final fresh = _scanWindow(startAbs, endAbs, cols, scanPatterns);
      for (final f in fresh) {
        if (f.payload == match.payload) return match;
      }
      return null;
    }

    // Shifted frame (#883). If the shift came from a scrollback shrink, the
    // content moved UP in absolute rows by AT LEAST the observed drop (same-
    // burst appends make the true shift larger). Try to re-locate the same
    // payload there; on success adopt the fresh coordinates.
    if (drop > 0) {
      var startAbs = top - drop - _relocateRowSlack;
      if (startAbs < 0) startAbs = 0;
      var endAbs = bottom + 1 - drop + _relocateRowSlack;
      if (endAbs > maxEndAbs) endAbs = maxEndAbs;
      if (endAbs - startAbs > 0) {
        final fresh = _scanWindow(startAbs, endAbs, cols, scanPatterns);
        for (final f in fresh) {
          if (f.payload == match.payload) return f;
        }
      }
    }
    // Could not confirm presence OR absence under a shifted frame — keep the
    // match and let the debounced rescan re-anchor (or drop) it from content.
    return match;
  }

  /// Scan absolute screen rows [startAbs, [endAbs]) with the production
  /// scanner/patterns (the prune's bounded re-read).
  List<StructuredMatch> _scanWindow(
    int startAbs,
    int endAbs,
    int cols,
    List<TextPattern> scanPatterns,
  ) {
    final reader = _ScreenCellReader(
      terminal: terminal,
      cols: cols,
      startAbsRow: startAbs,
      endAbsRow: endAbs,
    );
    // #1044: this is the prune's per-match re-read — count + time it so the
    // replay perf suite can pin the prune cost.
    _detectionStats.pruneWindowScans++;
    final sw = Stopwatch()..start();
    final matches = _detectionScanner.scan(reader, scanPatterns);
    _detectionStats.pruneMicros += sw.elapsedMicroseconds;
    return matches;
  }

  /// #1044: the LOWEST absolute row a match's ranges touch — the row that
  /// decides whether the match lives fully in immutable scrollback.
  int _matchBottomRow(StructuredMatch m) {
    var bottom = m.ranges.first.bottomRow;
    for (final r in m.ranges) {
      if (r.bottomRow > bottom) bottom = r.bottomRow;
    }
    return bottom;
  }

  /// #1046: start (or keep) the miss-grace countdown for [m]. Idempotent —
  /// a match already in grace keeps its ORIGINAL deadline, so a streaming
  /// repaint cannot extend a truly-gone anchor's afterlife indefinitely.
  void _armMissGrace(StructuredMatch m) {
    if (_detectionMissTimers.containsKey(m)) return;
    _detectionMissTimers[m] = Timer(
      Duration(
        milliseconds: m.tier == TextTier.block
            ? _detectionMissGraceBlockMs
            : _detectionMissGraceMs,
      ),
      () => _onMissGraceExpired(m),
    );
  }

  /// #1046: the payload was re-confirmed (validated in place, relocated, or
  /// replaced by an equal fresh match) — the anchor is no longer missing.
  void _cancelMissGrace(StructuredMatch m) {
    _detectionMissTimers.remove(m)?.cancel();
  }

  /// #1046: cancel every pending miss-grace timer (dispose / pattern clear /
  /// full-set replacement).
  void _cancelAllMissGrace() {
    for (final t in _detectionMissTimers.values) {
      t.cancel();
    }
    _detectionMissTimers.clear();
  }

  /// #1046: the grace ran out with the payload still unaccounted for. One
  /// final validate/relocate attempt (content may have returned with no
  /// notify since), then evict for real.
  void _onMissGraceExpired(StructuredMatch m) {
    _detectionMissTimers.remove(m);
    if (_disposed) return;
    final live = _detectionMatches;
    final idx = live.indexOf(m); // identity equality
    if (idx < 0) return; // already resolved elsewhere
    try {
      final cols = _gridCols;
      final visibleRows = _gridRows;
      if (cols <= 0 || visibleRows <= 0) return; // degenerate: keep, rescan reconciles
      final scanPatterns = _currentScanPatterns();
      if (scanPatterns.isEmpty) return; // pattern-less paths clear wholesale
      final scrollback = terminal.scrollbackRows;
      final gridMatches =
          _scanWindow(scrollback, scrollback + visibleRows, cols, scanPatterns);
      final survivors = live.toList();
      final moved = _nearestRelocation(m, gridMatches, survivors);
      if (moved != null) {
        survivors[idx] = moved;
        _detectionStats.pruneRelocated++;
      } else {
        survivors.removeAt(idx);
      }
      _detectionMatches = survivors;
      highlights = _styledHighlights(survivors);
      _decorationNotifier.notify();
    } catch (_) {
      // Defensive: an FFI hiccup here must not crash — leave the match for
      // the debounced rescan's reconcile to settle.
    }
  }

  /// The pattern set a scan/prune should run RIGHT NOW — the registered
  /// patterns minus the #824/#834 alt-screen heuristic suppression.
  List<TextPattern> _currentScanPatterns() {
    final suppressHeuristics =
        _activeScreen == .alternate && _mouseTracking == .none;
    return suppressHeuristics
        ? [for (final p in _textPatterns.values) if (p.isOsc8Source) p]
        : _textPatterns.values.toList(growable: false);
  }

  /// #1046: among [gridMatches], the same-payload candidate NEAREST to the
  /// missed match [m] (by top-row distance) that is not just another live
  /// anchor's cells — a second occurrence of the same payload that is already
  /// anchored (in [survivors] or still pending in [_detectionMatches]) must
  /// not be double-claimed. Null when the payload is really gone.
  StructuredMatch? _nearestRelocation(
    StructuredMatch m,
    List<StructuredMatch> gridMatches,
    List<StructuredMatch> survivors,
  ) {
    final mTop = m.ranges.first.topRow;
    StructuredMatch? best;
    var bestDist = 1 << 30;
    for (final f in gridMatches) {
      if (f.patternId != m.patternId || f.payload != m.payload) continue;
      var claimed = false;
      for (final other in survivors) {
        if (!identical(other, m) && _sameMatch(other, f)) {
          claimed = true;
          break;
        }
      }
      if (!claimed) {
        for (final other in _detectionMatches) {
          if (!identical(other, m) && _sameMatch(other, f)) {
            claimed = true;
            break;
          }
        }
      }
      if (claimed) continue;
      final dist = (f.ranges.first.topRow - mTop).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = f;
      }
    }
    return best;
  }

  /// #767: re-scan the active screen plus a bounded scrollback window for every
  /// registered pattern, store the matches, and ASSIGN the resulting absolute-
  /// coordinate ranges to [highlights] (the existing painter draws them). A
  /// fresh scan emits absolute rows from the CURRENT scrollback length, so
  /// scrollback eviction is corrected by construction (no ghost mark). Defensive:
  /// a formatter/FFI hiccup must never crash the session, so it falls back to no
  /// detection.
  void _rescanDetections({bool bypassScrollGate = false}) {
    if (_textPatterns.isEmpty) {
      _cancelAllMissGrace();
      _detectionMatches = const [];
      return;
    }
    // #1044: while the viewport is actively scrolling, DEFER. A scroll cannot
    // change cell content (absolute rows are append-stable, VT writes only
    // address the grid), so the only work a mid-scroll rescan could do is
    // discover newly-revealed rows — not worth competing with fling frames
    // for FFI/regex time. [_onScrollSettled] runs exactly one reconcile on
    // the settle edge (the quiesce pass). [bypassScrollGate] is set ONLY by
    // [_onScrollSettledMaxWait] — the ceiling that force-scans when content
    // churn keeps the scroll state from ever settling (a bottom-following
    // repainting line); that path has already confirmed content is pending.
    if (_isScrolling && !bypassScrollGate) {
      _rescanPendingSettle = true;
      _detectionStats.rescansDeferredScrolling++;
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
    //
    // #834: but tmux ALSO runs full-screen on the alternate screen, and tmux is a
    // SHELL HOST — its content is real shell output with NAVIGABLE URLs, not an
    // editor's incidental paths. Blanket alt-screen suppression killed detection
    // for the whole tmux session (the owner's daily-digest URL went unbubbled).
    // tmux enables MOUSE TRACKING (`?1000/?1002/?1006`), the exact discriminator
    // the gesture stack already trusts to tell a shell host from a path-editing
    // TUI (vim/less/htop leave mouse tracking off by default). So suppress the
    // heuristic patterns only on the alt-screen WITHOUT mouse tracking; with mouse
    // tracking on (tmux mouse mode) run the full pattern set.
    final suppressHeuristics =
        _activeScreen == .alternate && _mouseTracking == .none;
    final scanPatterns = suppressHeuristics
        ? [for (final p in _textPatterns.values) if (p.isOsc8Source) p]
        : _textPatterns.values.toList(growable: false);
    if (scanPatterns.isEmpty) {
      // On the alt-screen with no OSC-8 source registered there is nothing to
      // detect; drop any anchors carried over from the primary screen so the
      // underlines vanish the instant vim opens, and wake the decorator.
      _invalidateDetectionScanCache();
      _cancelAllMissGrace();
      if (_detectionMatches.isEmpty) return;
      _detectionMatches = const [];
      highlights = const [];
      _decorationNotifier.notify();
      return;
    }
    try {
      final visibleRows = _gridRows;
      final cols = _gridCols;
      if (visibleRows <= 0 || cols <= 0) {
        // Degenerate mid-layout dims — keep the pre-#1044 behavior (clear the
        // matches) and drop the cache with them.
        _invalidateDetectionScanCache();
        _cancelAllMissGrace();
        if (_detectionMatches.isEmpty) return;
        _detectionMatches = const [];
        highlights = const [];
        _decorationNotifier.notify();
        return;
      }
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
      // #958: the viewport top in SCREEN space. On the ALT screen
      // `scrollbar.offset` is alt-local (always 0) while the alt viewport
      // actually sits AFTER the primary history in `PointTag.screen` space —
      // using the raw offset made the scan window cover primary HISTORY rows
      // instead of the visible alt rows, so with history longer than the
      // margin nothing on a tmux screen was ever detected (the other half of
      // #958). See [screenViewportTop].
      final viewportTop =
          _activeScreen == .alternate ? scrollback : scrollbar.offset;
      final startAbs = viewportTop - _detectionScrollbackWindow < 0
          ? 0
          : viewportTop - _detectionScrollbackWindow;
      // Clamp the bottom to the last buffer row so we never read past the
      // active screen (defensive; the reader also guards per-cell).
      final maxEndAbs = scrollback + visibleRows; // exclusive
      var endAbs = viewportTop + visibleRows + _detectionScrollbackWindow;
      if (endAbs > maxEndAbs) endAbs = maxEndAbs;
      if (endAbs <= startAbs) return;

      // ---- #1044: the content-keyed scan cache ----
      // The cache claims: every row in [_scannedLo, _scannedHi) still holds
      // the content it held when [_detectionMatches] was reconciled. Valid
      // only while the coordinate frame holds (no scrollback shrink, no
      // resize, same screen) and the effective pattern set is unchanged.
      // Frame STABILITY is separate from cache COVERAGE: a zero-scrollback
      // TUI dirties its whole (all-grid) coverage on every repaint — the
      // cache goes empty but the coordinate frame is perfectly stable, and
      // the #1046 miss grace must keep applying there. Only a real frame
      // shift (scrollback shrink, resize, screen/suppression flip) makes
      // stored rows garbage.
      final frameStable = _scannedLo >= 0 &&
          scrollback >= _scannedScrollback &&
          cols == _scannedCols &&
          visibleRows == _scannedRows &&
          _activeScreen == _scannedScreen &&
          suppressHeuristics == _scannedSuppressHeuristics;
      var cacheValid = frameStable;
      if (cacheValid && _contentDirty) {
        // Content arrived since the last scan: every row that has been part
        // of the MUTABLE active grid since then (>= _scannedGridLo — a suffix
        // of the buffer, since the grid is always the bottom rows) is
        // suspect. Trim the cache to its clean prefix; the suspect suffix
        // falls into the extension region below and is re-read.
        _scannedHi =
            _scannedGridLo < _scannedLo ? _scannedLo : _scannedGridLo;
        if (_scannedHi > maxEndAbs) _scannedHi = maxEndAbs;
        if (_scannedHi <= _scannedLo) cacheValid = false;
      }
      // A window disjoint from the cached range (a scroll-to-top jump) would
      // leave an unscanned gap inside the single contiguous coverage
      // interval — fall back to a full window scan.
      if (cacheValid && (startAbs > _scannedHi || endAbs < _scannedLo)) {
        cacheValid = false;
      }

      // The CORE regions that must actually be read.
      final regions = <(int, int)>[];
      if (!cacheValid) {
        regions.add((startAbs, endAbs));
      } else {
        if (startAbs < _scannedLo) regions.add((startAbs, _scannedLo));
        if (endAbs > _scannedHi) regions.add((_scannedHi, endAbs));
      }

      if (regions.isEmpty) {
        // Pure viewport movement over already-scanned rows: ZERO cell reads,
        // zero regex passes — the #1044 core promise. The live matches are
        // still current by the immutability invariant, so nothing to notify.
        _detectionStats.rescanCacheHits++;
        _contentDirty = false;
        _scannedGridLo = scrollback;
        _scannedScrollback = scrollback;
        return;
      }

      // Read each core region EXTENDED to logical-line boundaries (wrap
      // flags) plus a fixed block-join slack, so a wrapped/joined match
      // crossing a region edge assembles exactly as a full scan would. The
      // extension rows are context only — they are already covered by the
      // cache — so fresh matches are ADOPTED only when they intersect a CORE
      // region (cached instances are authoritative for pure-extension rows).
      final fresh = <StructuredMatch>[];
      final sw = Stopwatch()..start();
      for (final (coreLo, coreHi) in regions) {
        var lo = coreLo - _detectionRegionJoinSlack;
        if (lo < 0) lo = 0;
        var guard = 0;
        while (lo > 0 && guard < _detectionRegionWrapCap && _absRowWrap(lo - 1)) {
          lo--;
          guard++;
        }
        var hi = coreHi + _detectionRegionJoinSlack;
        if (hi > maxEndAbs) hi = maxEndAbs;
        guard = 0;
        while (hi < maxEndAbs &&
            guard < _detectionRegionWrapCap &&
            _absRowWrap(hi - 1)) {
          hi++;
          guard++;
        }
        final reader = _ScreenCellReader(
          terminal: terminal,
          cols: cols,
          startAbsRow: lo,
          endAbsRow: hi,
        );
        _detectionStats.rescanRows += hi - lo;
        for (final m in _detectionScanner.scan(reader, scanPatterns)) {
          if (_matchIntersects(m, coreLo, coreHi)) fresh.add(m);
        }
      }
      _detectionStats.rescans++;
      _detectionStats.rescanMicros += sw.elapsedMicroseconds;

      // New contiguous coverage = cached ∪ window, trimmed to the retention
      // band around the viewport (coverage and its matches must not grow
      // unboundedly over a long scroll session).
      var newLo = cacheValid && _scannedLo < startAbs ? _scannedLo : startAbs;
      var newHi = cacheValid && _scannedHi > endAbs ? _scannedHi : endAbs;
      final keepLo = viewportTop - _detectionCacheRetentionRows;
      final keepHi =
          viewportTop + visibleRows + _detectionCacheRetentionRows;
      if (newLo < keepLo) newLo = keepLo;
      if (newLo < 0) newLo = 0;
      if (newHi > keepHi) newHi = keepHi;

      // ---- identity-preserving reconcile (#1046) ----
      // graceUnmatched only within a STABLE coordinate frame: after a frame
      // shift (scrollback clear/eviction, resize, screen flip) the stored
      // rows are garbage, so an unmatched cached anchor is dropped outright
      // (pre-#1046 semantics; keeps ESC[3J from leaving 350ms ghosts at
      // wrong rows). A merely-empty cache (all-grid coverage dirtied by a
      // TUI repaint) keeps the grace — the frame is stable there.
      final merged = _reconcileDetections(fresh, regions, newLo, newHi,
          graceUnmatched: frameStable);

      _scannedLo = newLo;
      _scannedHi = newHi;
      _scannedGridLo = scrollback;
      _scannedScrollback = scrollback;
      _scannedCols = cols;
      _scannedRows = visibleRows;
      _scannedScreen = _activeScreen;
      _scannedSuppressHeuristics = suppressHeuristics;
      _contentDirty = false;
      // #883: a fresh scan emits absolute rows in the CURRENT coordinate
      // frame — record that frame as the matches' anchor epoch so the
      // synchronous prune can tell a real in-place content change (frame
      // unchanged → evict, #873) from coordinate drift after a scrollback
      // eviction/clear or a resize reflow (frame shifted → keep/re-locate).
      _detectionFrameScrollback = scrollback;
      _detectionFrameCols = cols;
      _detectionFrameRows = visibleRows;

      if (merged == null) {
        // The reconciled set is element-wise IDENTICAL to the live one: an
        // unchanged rescan must be invisible to the gutter/bubble layers —
        // no reassignment, no bake, no decoration notify. This is the #1046
        // churn killer: a TUI repainting a row with identical content keeps
        // its anchor INSTANCE and its chip never blinks.
        _detectionStats.notifiesSuppressed++;
        return;
      }
      _detectionMatches = merged;
    } catch (_) {
      // A read/FFI hiccup must never crash the session — and (post-#883
      // stance) must not spuriously clear live anchors either. Drop the cache
      // (unknown state) and let the next pass reconcile from content.
      _invalidateDetectionScanCache();
      return;
    }
    highlights = _styledHighlights(_detectionMatches);
    // #805: the detected anchor set just changed (a settled re-scan), so wake the
    // narrow decoration listener — the decorator layer re-resolves now, not on
    // every mid-scroll redraw notify. (highlights= already fired the general
    // notify for the built-in HighlightPainter.)
    _decorationNotifier.notify();
  }

  /// #1044: drop the scan cache — the next [_rescanDetections] performs a
  /// full window scan. Called whenever the cached per-row results can no
  /// longer be trusted wholesale (pattern-set change, screen churn, FFI
  /// hiccup).
  void _invalidateDetectionScanCache() {
    _scannedLo = -1;
    _scannedHi = -1;
    _contentDirty = true;
  }

  /// #1044: whether any of [m]'s ranges touch absolute rows [lo, hi).
  bool _matchIntersects(StructuredMatch m, int lo, int hi) {
    for (final r in m.ranges) {
      if (r.topRow < hi && r.bottomRow >= lo) return true;
    }
    return false;
  }

  /// #1044: whether ALL of [m]'s rows lie inside covered rows [lo, hi).
  bool _matchWithin(StructuredMatch m, int lo, int hi) {
    for (final r in m.ranges) {
      if (r.topRow < lo || r.bottomRow >= hi) return false;
    }
    return true;
  }

  /// #1044: libghostty's authoritative soft-wrap flag for an ABSOLUTE screen
  /// row (true iff it continues onto the next row). Defensive like the cell
  /// reader — a read hiccup reads as "no wrap".
  bool _absRowWrap(int absRow) {
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

  /// #1044/#1046: merge freshly-scanned matches with the still-covered cached
  /// ones, PRESERVING INSTANCE IDENTITY for matches whose content did not
  /// change. Returns the merged list, or null when it is element-wise
  /// identical to the live [_detectionMatches] (caller then skips the bake +
  /// notify entirely).
  ///
  ///   * cached matches outside the new coverage band are dropped (they will
  ///     re-anchor from content when scrolled back into the window);
  ///   * cached matches intersecting a re-scanned CORE region are replaced by
  ///     the fresh finds — but a fresh match VALUE-equal to a replaced one
  ///     adopts the OLD instance, so an unchanged row re-scanned keeps its
  ///     anchor identity (no gutter unregister/re-register churn, #1046);
  ///   * cached matches in untouched covered rows are kept as-is;
  ///   * fresh matches may extend past the coverage edge (a wrap-extended
  ///     read) — they are real, freshly-read content, so they stand.
  List<StructuredMatch>? _reconcileDetections(
    List<StructuredMatch> fresh,
    List<(int, int)> coreRegions,
    int coveredLo,
    int coveredHi, {
    required bool graceUnmatched,
  }) {
    bool inScanned(StructuredMatch m) {
      for (final (lo, hi) in coreRegions) {
        if (_matchIntersects(m, lo, hi)) return true;
      }
      return false;
    }

    final merged = <StructuredMatch>[];
    final replaced = <StructuredMatch>[];
    for (final m in _detectionMatches) {
      if (!_matchWithin(m, coveredLo, coveredHi)) {
        _cancelMissGrace(m); // trimmed out of coverage
        continue;
      }
      if (inScanned(m)) {
        replaced.add(m); // identity-reuse candidate for an equal fresh match
      } else {
        merged.add(m);
      }
    }
    for (final f in fresh) {
      var adopted = f;
      for (var i = 0; i < replaced.length; i++) {
        if (_sameMatch(replaced[i], f)) {
          adopted = replaced.removeAt(i);
          _cancelMissGrace(adopted); // re-confirmed by the fresh scan
          _detectionStats.matchesReused++;
          break;
        }
      }
      merged.add(adopted);
    }
    // #1046: cached matches in a re-scanned region with NO equal fresh match.
    // A same-payload fresh match elsewhere means the line MOVED — the fresh
    // instance carries it on (atomic move; drop the stale one). Otherwise the
    // payload is unaccounted for RIGHT NOW, which mid-repaint is routinely a
    // transient — keep it under the same miss grace the prune uses; the
    // grace timer (or a later scan) settles it for real.
    for (final m in replaced) {
      var movedElsewhere = false;
      for (final f in fresh) {
        if (f.patternId == m.patternId && f.payload == m.payload) {
          movedElsewhere = true;
          break;
        }
      }
      if (movedElsewhere) {
        _cancelMissGrace(m);
        continue; // the fresh match IS this anchor at its new rows
      }
      if (!graceUnmatched) {
        _cancelMissGrace(m); // frame shifted — the rows are garbage; drop
        continue;
      }
      merged.add(m);
      _armMissGrace(m);
    }
    merged.sort(_compareMatches);
    if (merged.length == _detectionMatches.length) {
      var same = true;
      for (var i = 0; i < merged.length; i++) {
        if (!identical(merged[i], _detectionMatches[i])) {
          same = false;
          break;
        }
      }
      if (same) return null;
    }
    return merged;
  }

  /// #1046: VALUE equality between a cached and a fresh match — same pattern,
  /// tier, honesty flag, payload, and per-row ranges. This is "the row
  /// re-scanned to the identical result", the condition under which the old
  /// instance keeps its identity.
  bool _sameMatch(StructuredMatch a, StructuredMatch b) {
    if (a.patternId != b.patternId ||
        a.tier != b.tier ||
        a.maybeIncomplete != b.maybeIncomplete ||
        a.payload != b.payload ||
        a.ranges.length != b.ranges.length) {
      return false;
    }
    for (var i = 0; i < a.ranges.length; i++) {
      if (a.ranges[i] != b.ranges[i]) return false;
    }
    return true;
  }

  /// #1044: deterministic reading-order sort for the reconciled match list
  /// (top row, then start col, then pattern id) — mirrors the line order a
  /// full-window scan emitted, which [matchAt]'s "last containing wins"
  /// tie-break was written against.
  static int _compareMatches(StructuredMatch a, StructuredMatch b) {
    final ra = a.ranges.first;
    final rb = b.ranges.first;
    if (ra.topRow != rb.topRow) return ra.topRow - rb.topRow;
    if (ra.startCol != rb.startCol) return ra.startCol - rb.startCol;
    return a.patternId.compareTo(b.patternId);
  }

  @override
  List<bool> get viewportRowWraps {
    final rows = _gridRows;
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
    // #1044: NO prune here. A viewport scroll cannot change cell content —
    // absolute screen rows are append-stable (#883) and VT writes only address
    // the active grid — so the per-tick synchronous re-validation this used to
    // run (every live match re-read cell-by-cell over FFI plus a full pattern
    // pass, EVERY scroll frame) was pure waste: the dominant per-frame cost of
    // the #1044 fling lag. Content changes arrive via _onTerminalChanged,
    // which still prunes. Discovery of newly-revealed rows stays debounced
    // below (and defers to the settle edge while the fling is live).
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
    _detectionMaxWait?.cancel();
    _cancelAllMissGrace();
    _scrollSettleTimer?.cancel();
    _scrollSettleMaxWait?.cancel();
    terminal.removeListener(_onTerminalChanged);
    detach();
    _keyEvent.dispose();
    _mouseEvent.dispose();
    _keyEncoder.dispose();
    _mouseEncoder.dispose();
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
    // Paint-staleness root fix: this is the single seam through which the
    // render box resizes the terminal, so the cached grid the read paths use
    // (instead of a damage-consuming RenderState.update) can never diverge.
    _gridCols = cols;
    _gridRows = rows;
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
    // #883: jump the ScrollController FIRST, while the FFI scrollbar still
    // holds the OLD offset. The render box's `_onScroll` derives its scroll
    // delta as `targetOffset - scrollbar.offset`; with the old order
    // (`terminal.scrollToTop()` before `jumpTo(0)`) the FFI offset was
    // already 0 when the jump landed, so the delta was 0 and `_onScroll`
    // returned WITHOUT marking the frame dirty. The glyphs never repainted
    // at the top and `reportPaintedViewportOffset(0)` never fired, leaving
    // [_paintedViewportOffset] stale at the bottom value indefinitely (no
    // further output → no other repaint refreshes the frame's offset).
    // [matchAt]/[highlightAt] — which map viewport→absolute via the PAINTED
    // offset so hit-test and paint share one geometry source (#863) — then
    // resolved against a wrong absolute row: a tap (or the #767 acceptance
    // test) on the URL at the top of scrollback found nothing. Jumping first
    // gives `_onScroll` the real delta → `scrollViewport` + frame-dirty →
    // the next paint syncs and reports offset 0. `terminal.scrollToTop()`
    // remains as the backstop for the detached/headless case (no clients)
    // and is an idempotent no-op after the jump-driven scroll.
    final controller = _scrollController;
    if (controller != null && controller.hasClients) controller.jumpTo(0);
    terminal.scrollToTop();
  }

  @override
  void selectAll() {
    terminal.scrollToBottom();
    final scrollbackLen = terminal.scrollbackRows;
    final rows = _gridRows;
    final cols = _gridCols;

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

    final cols = _gridCols;
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
  String textForRows(
    int topRowAbs,
    int bottomRowAbs, {
    FormatterFormat format = .plain,
  }) {
    final cols = _gridCols;
    final total = terminal.totalRows;
    if (cols <= 0 || total <= 0) return '';
    var top = topRowAbs;
    var bottom = bottomRowAbs;
    if (top > bottom) {
      final swap = top;
      top = bottom;
      bottom = swap;
    }
    top = top.clamp(0, total - 1);
    bottom = bottom.clamp(0, total - 1);
    final formatter = Formatter(
      terminal: terminal,
      format: format,
      unwrap: true,
      selection: Selection(
        startCol: 0,
        startRow: top,
        endCol: (cols - 1).clamp(0, cols - 1),
        endRow: bottom,
        rectangle: false,
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
  String visibleRowsText(int topViewRow, int bottomViewRow) {
    final cols = _gridCols;
    if (cols <= 0) return '';
    var top = topViewRow;
    var bottom = bottomViewRow;
    if (top > bottom) {
      final swap = top;
      top = bottom;
      bottom = swap;
    }
    if (top < 0) top = 0;
    if (bottom < 0) return '';

    final out = StringBuffer();
    for (var r = top; r <= bottom; r++) {
      final line = StringBuffer();
      // Whether the LAST column (cols-1) holds real content — a row that fills
      // the full width and continued onto the next row (see the wrap join
      // below). Reset per row.
      var endFilled = false;
      for (var c = 0; c < cols; c++) {
        GridRef? ref;
        try {
          // PointTag.viewport: row r is the r-th VISIBLE row (what's painted
          // now) — no scrollback/offset math.
          ref = GridRef.at(terminal, col: c, row: r, pointTag: .viewport);
          final atEnd = c == cols - 1;
          // A wide-char spacer tail carries no text of its own — but if it sits
          // in the last column, a wide glyph fills the width to the margin.
          if (ref.wide == CellWidth.spacerTail) {
            if (atEnd) endFilled = true;
            continue;
          }
          // A BLANK cell (`content` == '') is a visual space of width 1 — emit
          // ' ' so INTERIOR + leading spaces survive. Ghostty stores blanks
          // (incl. the gaps a TUI leaves between tokens via cursor positioning)
          // as empty graphemes; writing '' collapsed them, so `curl -fsSL https`
          // copied as `curl-fsSLhttps`. Trailing padding is trimmed below.
          final ch = ref.content;
          if (atEnd && ch.isNotEmpty) {
            // A row that reaches the margin with content overflowed — EXCEPT a
            // box-drawing / block-element edge (│ ─ ╮ █ …, U+2500–U+259F), which
            // is a border, not a wrapped line. Excluding it keeps TUI box art as
            // separate lines while still joining wrapped URLs / command lines.
            final r0 = ch.runes.first;
            if (r0 < 0x2500 || r0 > 0x259F) endFilled = true;
          }
          line.write(ch.isEmpty ? ' ' : ch);
        } catch (_) {
          // Out-of-range (past the last visible row/col) → treat as blank.
        } finally {
          ref?.dispose();
        }
      }
      // WRAP JOIN (default). Two signals mean this visual row and the next are
      // ONE logical line — join them (write the row, no trailing trim, no '\n')
      // so long URLs and command lines paste back intact instead of breaking at
      // the margin:
      //   1. `rowWrap` — ghostty's own soft-wrap bookkeeping (a long line typed
      //      at a prompt / emitted by a program).
      //   2. `endFilled` — the row reached the right edge with content. Many
      //      wraps (tmux panes, forced-margin TUIs like Claude Code) fill the
      //      width and continue WITHOUT setting rowWrap; without this a wrapped
      //      URL keeps its newline and breaks. A row that ends before the margin
      //      (trailing blanks → endFilled false) is a real line end and keeps
      //      its '\n'.
      var rowWrapFlag = false;
      GridRef? wrapRef;
      try {
        wrapRef = GridRef.at(terminal, col: 0, row: r, pointTag: .viewport);
        rowWrapFlag = wrapRef.rowWrap;
      } catch (_) {
        // Out-of-range → treat as unwrapped.
      } finally {
        wrapRef?.dispose();
      }
      final wrapped = rowWrapFlag || endFilled;
      final s = line.toString();
      if (wrapped && r < bottom) {
        out.write(s);
      } else {
        // Trim trailing blanks so a line isn't padded to the full width.
        out.write(s.replaceFirst(RegExp(r'[ \t]+$'), ''));
        if (r < bottom) out.write('\n');
      }
    }
    return out.toString();
  }

  @override
  void selectLine(int row, LineSelectMode lineSelectMode) {
    final (:startRow, :endRow, :endCol) = terminal.lineBoundaryAt(
      row,
      cols: _gridCols,
      rows: _gridRows,
    );
    final int effectiveEndCol;
    switch (lineSelectMode) {
      case .full:
        effectiveEndCol = _gridCols;
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
    final adjCol = terminal.snapColToWideBoundary(
      row,
      col,
      inclusive: true,
      cols: _gridCols,
      rows: _gridRows,
    );
    final (startCol, endCol) = terminal.wordBoundaryAt(
      row,
      adjCol,
      wordPattern: _config.wordPattern,
      cols: _gridCols,
      rows: _gridRows,
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
      cols: _gridCols,
      rows: _gridRows,
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
    selection = _selection!.moveEnd(
      dRow,
      dCol,
      totalCols: _gridCols,
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
    return TerminalSizeInfo(
      rows: _gridRows,
      columns: _gridCols,
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

    // #767: a notify means the cells may have changed (output streamed) or the
    // viewport scrolled; re-scan registered structured-text patterns on a
    // debounce so the highlights track new content. No-op when none registered.
    // This only (re)arms a Timer — safe to run mid-frame (it fires outside it).
    // #1044: a TERMINAL notify (unlike a scroll notify) may have rewritten the
    // active grid in place — mark the mutable suffix dirty so the next rescan
    // re-reads it (and only it).
    _contentDirty = true;
    _scheduleDetectionRescan();

    // #887: the remaining work emits notifications that REBUILD or read layout
    // geometry — `_scrollToBottomOnOutput` (scroll controller notify), the
    // prune/synchronous rescan (`highlights=` general notify +
    // `_decorationNotifier.notify()`), and the `changed` notify. When this
    // terminal notify arrived DURING a frame's layout/paint phase (libghostty's
    // `Terminal.resize` fired synchronously from `performLayout`), running them
    // now throws "RenderBox.size accessed beyond the scope…" /
    // "Build scheduled during frame". Defer to the next post-frame callback in
    // that case; run synchronously otherwise so #873 eviction stays immediate.
    _runOrDeferFrameWork(leftAlternateScreen, changed);
  }

  /// #887: the notify-producing tail of [_onTerminalChanged]. Runs synchronously
  /// when it is safe to schedule rebuilds / read render geometry, and is
  /// otherwise deferred (whole) to one post-frame callback. See
  /// [_deferredFrameWorkScheduled].
  void _runOrDeferFrameWork(bool leftAlternateScreen, bool changed) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final midFrame = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (!midFrame) {
      _applyFrameWork(leftAlternateScreen, changed);
      return;
    }
    // Mid-frame: coalesce this and any further mid-frame notifies in the SAME
    // frame into one post-frame pass. `leftAlternateScreen`/`changed` need not
    // be carried — the deferred pass re-reads the live terminal state (the
    // prune/rescan read cells directly) and always notifies, which is the
    // superset of what an individual mid-frame notify would have done.
    if (_deferredFrameWorkScheduled) return;
    _deferredFrameWorkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deferredFrameWorkScheduled = false;
      if (_disposed) return;
      // Re-derive leftAlternateScreen would require remembering it; the
      // post-frame pass simply runs the full detection reconcile + notify.
      // Force a synchronous rescan so a vim-exit that happened mid-frame still
      // re-anchors immediately on the next frame (parity with the inline path).
      _applyFrameWork(true, true);
    });
  }

  /// #887: the deferrable side-effects extracted from [_onTerminalChanged].
  void _applyFrameWork(bool leftAlternateScreen, bool changed) {
    if (_disposed) return;
    _scrollToBottomOnOutput();
    // #873: a redraw may have rewritten the cells UNDER a live anchor (tmux/app
    // repaints a row, or content scrolled past the bounded window). DISCOVERY of
    // new matches stays debounced (above), but EVICTION of a now-stale anchor
    // must be immediate — synchronously re-validate the live anchors against the
    // current cells and drop any whose run no longer carries the matched text, so
    // no orphaned highlight box lingers through the debounce window. No-op when no
    // anchors are live or no pattern is registered.
    _pruneStaleDetections();
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
