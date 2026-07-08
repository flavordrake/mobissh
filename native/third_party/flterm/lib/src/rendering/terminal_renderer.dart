import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart';

import '../foundation.dart';
import 'atlas/atlas_config.dart';
import 'paint_state.dart';
import 'terminal_render_cache.dart';
import 'terminal_render_pipeline.dart';

/// Renders a terminal screen with cell backgrounds, styled text, cursors,
/// and selection overlays.
///
/// This is the core rendering widget used internally by [TerminalView].
/// It owns a [TerminalRenderBox] that orchestrates layout (grid sizing,
/// terminal resize), frame sync, and a paint stack.
///
/// Sizing is determined by the parent constraints and cell metrics: the
/// widget computes how many columns and rows fit, then sizes itself to
/// exactly that grid. When the grid dimensions change, the terminal is
/// resized and [onResize] fires.
///
/// ```dart
/// TerminalRenderer(
///   terminal: myTerminal,
///   theme: TerminalTheme.dark(),
///   metrics: measureCellMetrics(fontFamily: 'monospace', fontSize: 14),
///   offset: ViewportOffset.zero(),
///   renderObserver: controller,
/// )
/// ```
class TerminalRenderer extends LeafRenderObjectWidget {
  /// The terminal whose screen is rendered.
  final Terminal terminal;

  /// Visual style applied to the terminal.
  ///
  /// When changed, theme colors are pushed to the terminal (foreground,
  /// background, palette, cursor color), the glyph atlas is updated if
  /// font properties changed, and a full repaint is scheduled.
  final TerminalTheme theme;

  /// Cell pixel dimensions used for grid sizing and coordinate conversion.
  ///
  /// When changed, the glyph atlas is cleared and layout is recalculated.
  /// A grid dimension change triggers terminal resize and [onResize].
  final CellMetrics metrics;

  /// Scroll offset provided by a [Scrollable] ancestor.
  ///
  /// At `pixels == 0`, the oldest scrollback row is visible.
  /// At `pixels == maxScrollExtent`, the live screen is visible.
  final ViewportOffset offset;

  /// Observable state for selection and focus.
  ///
  /// Listened to by the render box. Changes trigger a repaint to update
  /// selection highlights and cursor appearance (filled vs hollow).
  final TerminalRenderObserver renderObserver;

  /// Whether the cursor blink is currently in the visible phase.
  ///
  /// When false, the cursor and blinking text (SGR 5) are hidden.
  /// Toggled by a timer in [TerminalView].
  final bool blinkVisible;

  /// IME preedit text to draw at the cursor before it is committed.
  final String preeditText;

  /// Called when the terminal grid dimensions change during layout.
  ///
  /// Fires after the terminal has been resized. Use this to notify the
  /// backend (PTY, SSH) of the new dimensions.
  final OnResize? onResize;

  /// Internal render cache used to share compatible atlas state.
  final TerminalRenderCache renderCache;

  const TerminalRenderer({
    super.key,
    required this.terminal,
    required this.theme,
    required this.metrics,
    required this.offset,
    required this.renderObserver,
    required this.renderCache,
    this.blinkVisible = true,
    this.preeditText = '',
    this.onResize,
  });

  @override
  TerminalRenderBox createRenderObject(BuildContext context) {
    return TerminalRenderBox(
      theme: theme,
      offset: offset,
      metrics: metrics,
      terminal: terminal,
      renderCache: renderCache,
      onResize: onResize,
      blinkVisible: blinkVisible,
      preeditText: preeditText,
      renderObserver: renderObserver,
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty<Terminal>('terminal', terminal))
      ..add(DiagnosticsProperty<TerminalTheme>('theme', theme))
      ..add(DiagnosticsProperty<CellMetrics>('metrics', metrics))
      ..add(
        DiagnosticsProperty<TerminalSelection?>(
          'selection',
          renderObserver.selection,
        ),
      )
      ..add(DiagnosticsProperty<ViewportOffset>('offset', offset))
      ..add(
        FlagProperty(
          'blinkVisible',
          value: blinkVisible,
          ifTrue: 'blink visible',
        ),
      )
      ..add(StringProperty('preeditText', preeditText, defaultValue: ''));
  }

  @override
  void updateRenderObject(
    BuildContext context,
    TerminalRenderBox renderObject,
  ) {
    renderObject
      ..terminal = terminal
      ..theme = theme
      ..renderCache = renderCache
      ..offset = offset
      ..metrics = metrics
      ..onResize = onResize
      ..renderObserver = renderObserver
      ..blinkVisible = blinkVisible
      ..preeditText = preeditText;
  }
}

/// Render object orchestrating terminal layout, state sync, and painting.
///
/// Three phases per frame:
///
/// 1. **Layout**: computes grid size from constraints and [CellMetrics],
///    configures the glyph atlas for the current DPR, resizes the terminal
///    if the grid changed, and updates scroll extents.
///
/// 2. **Sync** (start of paint): snapshots terminal cells, resolves colors
///    (including OSC 10/11 overrides, bold-is-bright, inverse, faint),
///    builds frame data for text/backgrounds/decorations, resolves
///    the cursor cell glyph, and collects Kitty graphics placements.
///
/// 3. **Paint**: delegates to a paint stack that owns painter instances,
///    Kitty image snapshots, and z-order.
///
/// Created and managed by [TerminalRenderer]. Not intended for direct use.
class TerminalRenderBox extends RenderBox {
  Terminal _terminal;
  ViewportOffset _offset;
  TerminalRenderObserver _renderObserver;
  OnResize? _onResize;
  TerminalRenderCache _renderCache;
  late TerminalAtlasHandle _atlasHandle;
  var _performingLayout = false;
  var _needsFrameSync = false;
  var _stickToBottom = true;
  var _lastScrollbackRows = 0;
  var _preeditText = '';

  // #921: whether structured-text DETECTION (URL/path patterns) is registered on
  // the controller. When true, a SECOND libghostty `RenderState` handle (the
  // controller's detection handle) competes to consume the shared terminal's
  // per-row damage — and registers its listener BEFORE this render box, so on a
  // synchronous content notify it consumes the damage before this box's
  // `_onTerminalChanged` runs, leaving the partial build with nothing to re-read.
  // When this is set, the PRIMARY screen forces a full visible-grid re-read on
  // each content change (the same decoupling the #900 fix uses for the alternate
  // screen) so the paint is immune to that single-consumption race. Default false
  // keeps the detection-OFF streaming-output path (#805) on the partial-rebuild
  // path with no extra work.
  var _detectionActive = false;

  // #918 force-repaint robustness layer (the "tap Debug fixes it" mitigation).
  //
  // INPUT-DRIVEN: [forceRepaint] re-reads the FULL visible grid (markAllRowsDirty
  // + frame-dirty) — the SAME full repaint a route-push / Debug-overlay triggers —
  // coalesced to AT MOST ONCE per frame: a force sets `_forceCoalesced`, and the
  // next paint's `_syncFrameState` clears it, so N forces within one frame collapse
  // to one re-snapshot. This is a SAFETY NET on top of the #900 damage-consume fix.
  //
  // OUTPUT SETTLE TICK ("backend clock"): a PTY-output burst arms a one-shot timer
  // ([_outputSettleTimer]) that fires ONCE ~60ms after the burst and forces a frame,
  // covering non-user-initiated output the normal damage/frame path dropped. It MUST
  // NOT free-run when idle (no input, no output) — that regresses the #805 battery
  // perf guard — so it arms ONLY on a content-change notify and disarms after one fire.
  var _forceCoalesced = false;
  var _debugForceRepaintCount = 0;
  Timer? _outputSettleTimer;

  // PAINT-STACK BOUNDARY COUNTERS (paint replay harness). Monotonic since this
  // render box was created. Capture-only — no behaviour change. Together with
  // the app-side bytesIn/writeErrors counters they let a stale-paint report
  // name the broken layer: bytes arrived → terminal notified
  // ([debugContentNotifyCount]) → paint ran ([debugPaintCount]) → the sync
  // re-read rows ([debugFrameSyncCount] / [debugRowsRebuiltLastSync]).
  var _debugContentNotifyCount = 0;
  var _debugPaintCount = 0;
  var _debugFrameSyncCount = 0;

  // #922 TELEMETRY SEAM (capture only — NO behaviour change to paint/dirty/sync).
  //
  // When the app wires [onFrameDebug] (production flterm leaves it null → zero
  // cost), the render/sync path emits COMPACT, capturable lines so a device
  // capture of a stale tmux window switch shows WHY a switch didn't repaint:
  //   - primary↔alternate screen TRANSITIONS (a tmux window switch / full-screen
  //     app enter/exit),
  //   - every CONTENT sync that re-read ZERO rows (the smoking gun: markAllRowsDirty
  //     was in effect yet the build re-emitted nothing → paint skipped),
  //   - a collapsed summary of syncs that DID rebuild (so the cadence is visible),
  //   - the #918 output-settle tick ARM/FIRE (did the trailing re-read engage?).
  //
  // Identical consecutive content-sync lines collapse into a ` (xN)` run so a
  // streaming burst does not flood the ring (#805 / suppress-identical pattern).
  // Screen transitions, zero-rebuild syncs, and settle arm/fire are NEVER
  // collapsed away — they are the signal.
  void Function(String line)? onFrameDebug;

  // The activeScreen observed on the LAST notify, to detect transitions.
  TerminalScreen? _lastObservedScreen;
  // Whether the LAST notify applied markAllRowsDirty (alt-screen or detection).
  // The paint-time sync reads this so the emitted line reflects the decision the
  // notify actually made (sync runs later, at paint).
  var _lastNotifyMarkedAll = false;
  // Collapse state for the high-frequency rebuilt-summary line.
  String? _lastFrameDebugLine;
  var _lastFrameDebugCount = 0;

  /// The settle window between the LAST output byte and the forced frame. Long
  /// enough to coalesce a streaming burst into one tick, short enough to self-heal
  /// promptly. Bounded; the alternate/visible grid re-read is cheap.
  static const Duration kOutputSettle = Duration(milliseconds: 80);

  /// Injectable settle-timer factory (test seam). Production schedules a real
  /// [Timer]; headless tests inject a fake so the tick fires deterministically and
  /// the #805 idle-no-fire perf guard is assertable.
  Timer Function(Duration, void Function()) _scheduleSettleTimer = Timer.new;

  final TerminalPaintState _paintState;
  late final TerminalRenderPipeline _pipeline;

  TerminalRenderBox({
    required this._terminal,
    required TerminalTheme theme,
    required CellMetrics metrics,
    required this._offset,
    required this._renderObserver,
    required this._renderCache,
    bool blinkVisible = true,
    this._preeditText = '',
    this._onResize,
  }) : _paintState = TerminalPaintState(theme, metrics)
         ..blinkVisible = blinkVisible
         ..selection = _renderObserver.selection
         ..highlights = _renderObserver.highlights
         ..cursorFocused = _renderObserver.hasFocus {
    _atlasHandle = _renderCache.acquireAtlas(
      .fromTheme(
        theme: theme,
        metrics: metrics,
        devicePixelRatio: _currentDevicePixelRatio,
      ),
    );
    final atlas = _atlasHandle.atlas;
    _pipeline = TerminalRenderPipeline(
      atlas: atlas,
      state: _paintState,
      onImageReady: markNeedsPaint,
    );

    _applyTerminalThemeColors();
  }

  /// #921: whether structured-text detection is currently active. The widget
  /// layer sets this when at least one detect pattern (URL/path) is registered
  /// on the controller and clears it when patterns are cleared. When active, the
  /// primary screen forces a full visible-grid re-read on content change (see
  /// [_detectionActive]).
  bool get detectionActive => _detectionActive;

  set detectionActive(bool value) {
    if (_detectionActive == value) return;
    _detectionActive = value;
    // Turning detection ON: a fresh full re-read self-heals any frame that the
    // detection-driven extra sync's damage-consume already starved before this
    // flag was set (the live toggle / first-registration case). Bounded to
    // visible rows.
    if (value) {
      _pipeline.markAllRowsDirty();
      _markFrameDirty();
    }
  }

  /// #921 (test seam): the current detection-active flag.
  bool get debugDetectionActive => _detectionActive;

  bool get blinkVisible => _paintState.blinkVisible;

  set blinkVisible(bool value) {
    if (_paintState.blinkVisible == value) return;
    _paintState.blinkVisible = value;
    _pipeline.markAllRowsDirty();
    _pipeline.refreshCursorGlyph();
    markNeedsPaint();
  }

  set preeditText(String value) {
    if (_preeditText == value) return;
    _preeditText = value;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  /// Rows the LAST paint's frame-sync re-emitted (0 if it skipped the build).
  /// Test-only signal for the #900 repaint-on-every-redraw contract: an
  /// in-place alt-screen redraw (tmux window switch) must re-read the visible
  /// grid on EVERY switch, not every other one.
  int get debugRowsRebuiltLastSync => _pipeline.debugRowsRebuiltLastSync;

  /// #918 (test seam): how many times [forceRepaint] actually triggered a forced
  /// re-snapshot. Coalescing means N forces within one frame increment this once.
  int get debugForceRepaintCount => _debugForceRepaintCount;

  /// #918 (test seam): whether the output settle tick is currently armed (a timer
  /// is pending). The #805 perf guard asserts this is FALSE when idle.
  bool get debugOutputTickArmed => _outputSettleTimer != null;

  /// Paint replay harness: content-change notifies observed (a
  /// [_onTerminalChanged] that survived the rows==0 guard). Monotonic.
  int get debugContentNotifyCount => _debugContentNotifyCount;

  /// Paint replay harness: [paint] executions. Monotonic. A stale screen with
  /// bytes arriving but this NOT advancing = paint was never scheduled/ran.
  int get debugPaintCount => _debugPaintCount;

  /// Paint replay harness: paint-time frame syncs that ran with terminal-dirty
  /// content ([_syncFrameState] with `_needsFrameSync` set). Monotonic.
  int get debugFrameSyncCount => _debugFrameSyncCount;

  /// #918 (test seam): inject the settle-timer factory so headless tests fire the
  /// output tick deterministically and assert the idle-no-fire perf guard.
  void debugSetOutputSettleTickFactory(
    Timer Function(Duration, void Function()) factory,
  ) {
    _scheduleSettleTimer = factory;
  }

  /// #918 INPUT-DRIVEN force-repaint — re-read the FULL visible grid and repaint,
  /// the SAME full repaint a route-push / Debug-overlay triggers.
  ///
  /// Called by the widget layer after dispatching ANY user input to the PTY (key,
  /// tap, gesture, paste, keybar) so the UI self-heals on every interaction even if
  /// the normal libghostty damage/frame-sync path dropped the redraw (#900 is the
  /// correctness fix; this is the brute-force net on top). `markAllRowsDirty` makes
  /// the next sync's frame build re-read every visible row from the CURRENT snapshot
  /// even when libghostty reports clean (a prior frame consumed the per-row damage);
  /// `_markFrameDirty` sets `_needsFrameSync` + `markNeedsPaint`.
  ///
  /// COALESCED to once per frame: multiple inputs landing within a single frame set
  /// the flag once, and the next paint clears it — so we never force more than one
  /// bounded grid re-read per frame.
  void forceRepaint() {
    if (_paintState.rows == 0) return;
    if (_forceCoalesced) return;
    _forceCoalesced = true;
    _debugForceRepaintCount += 1;
    _pipeline.markAllRowsDirty();
    _markFrameDirty();
  }

  /// Current terminal input caret rect in this render box's local coordinates.
  Rect get textInputCaretRect {
    final metrics = _paintState.metrics;
    final rows = _paintState.rows;
    final cols = _paintState.cols;
    if (rows <= 0 || cols <= 0) {
      return Offset.zero & Size(metrics.cellWidth, metrics.cellHeight);
    }

    final cursor = _paintState.cursor;
    final row = cursor.row.clamp(0, rows - 1);
    final rawCol = cursor.wideTail && cursor.col > 0
        ? cursor.col - 1
        : cursor.col;
    final col = rawCol.clamp(0, cols - 1);
    return metrics.cellRect(row, col, .zero);
  }

  /// Current terminal composing rect in this render box's local coordinates.
  Rect get textInputComposingRect => textInputCaretRect;

  set metrics(CellMetrics value) {
    if (_paintState.metrics == value) return;
    _paintState.metrics = value;
    markNeedsLayout();
  }

  set offset(ViewportOffset value) {
    if (_offset == value) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  set onResize(OnResize? value) => _onResize = value;

  set renderObserver(TerminalRenderObserver value) {
    if (_renderObserver == value) return;
    if (attached) _renderObserver.removeListener(_onRenderObserverChanged);
    _renderObserver = value;
    if (attached) _renderObserver.addListener(_onRenderObserverChanged);
    _onRenderObserverChanged();
  }

  set renderCache(TerminalRenderCache value) {
    if (identical(value, _renderCache)) return;

    _renderCache = value;
    final atlasChanged = _acquireAtlasForCurrentConfig(force: true);
    if (atlasChanged) _markFrameDirty();
  }

  set terminal(Terminal value) {
    if (_terminal == value) return;
    if (attached) _terminal.removeListener(_onTerminalChanged);
    _terminal = value;
    if (attached) _terminal.addListener(_onTerminalChanged);
    _applyTerminalThemeColors();
    _needsFrameSync = true;
    markNeedsLayout();
  }

  TerminalTheme get theme => _paintState.theme;

  /// Updates the theme, clearing the atlas only if font properties changed.
  ///
  /// Color-only changes (palette, foreground, background) use markNeedsPaint
  /// which repaints with the existing atlas. Font changes (size, weight,
  /// family) use markNeedsLayout which reconfigures the atlas, re-measures
  /// the grid, and pre-seeds glyphs.
  set theme(TerminalTheme value) {
    if (_paintState.theme == value) return;
    final oldTheme = _paintState.theme;
    final fontChanged =
        oldTheme.fontSize != value.fontSize ||
        oldTheme.fontWeight != value.fontWeight ||
        oldTheme.fontFamily != value.fontFamily ||
        !_listEquals(oldTheme.fontFamilyFallback, value.fontFamilyFallback);
    _paintState.updateTheme(value);
    _applyTerminalThemeColors();
    _pipeline.markAllRowsDirty();
    _needsFrameSync = true;

    if (fontChanged) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _renderObserver.addListener(_onRenderObserverChanged);
    _terminal.addListener(_onTerminalChanged);
    markNeedsLayout();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('cols', _paintState.cols))
      ..add(IntProperty('rows', _paintState.rows))
      ..add(DiagnosticsProperty<TerminalTheme>('theme', _paintState.theme))
      ..add(DiagnosticsProperty<CellMetrics>('metrics', _paintState.metrics))
      ..add(
        DiagnosticsProperty<TerminalSelection?>(
          'selection',
          _paintState.selection,
        ),
      )
      ..add(
        FlagProperty(
          'blinkVisible',
          value: _paintState.blinkVisible,
          ifTrue: 'cursor visible',
        ),
      )
      ..add(
        DiagnosticsProperty<TerminalRenderObserver?>(
          'renderObserver',
          _renderObserver,
        ),
      );
  }

  @override
  void detach() {
    // #918: a detached box must not keep a pending settle tick alive (no free-run
    // off-screen).
    _outputSettleTimer?.cancel();
    _outputSettleTimer = null;
    _offset.removeListener(_onScroll);
    _renderObserver.removeListener(_onRenderObserverChanged);
    _terminal.removeListener(_onTerminalChanged);
    super.detach();
  }

  @override
  void dispose() {
    _outputSettleTimer?.cancel();
    _outputSettleTimer = null;
    _paintState.rows = 0;
    _paintState.cols = 0;
    _pipeline.dispose();
    _atlasHandle.release();
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    _debugPaintCount++;
    _syncFrameState();

    final canvas = context.canvas;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    _pipeline.paint(canvas);
    canvas.restore();
  }

  @override
  void performLayout() {
    _performingLayout = true;

    final maxW = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    final maxH = constraints.hasBoundedHeight ? constraints.maxHeight : 0.0;
    final (newCols, newRows) = _paintState.metrics.gridSize(maxW, maxH);

    size = constraints.constrain(
      Size(
        newCols * _paintState.metrics.cellWidth,
        newRows * _paintState.metrics.cellHeight,
      ),
    );

    final dpr = _currentDevicePixelRatio;
    final atlasReconfigured = _acquireAtlasForCurrentConfig(dpr: dpr);

    final gridChanged =
        newCols != _paintState.cols || newRows != _paintState.rows;
    if (gridChanged) {
      _paintState.cols = newCols;
      _paintState.rows = newRows;
      _paintState.devicePixelRatio = dpr;
      if (newCols > 0 && newRows > 0) {
        _pipeline.configureGrid(newRows, newCols);
        // Cell size is reported in physical pixels so size-report
        // escapes and Kitty graphics geometry match a native terminal
        // at the same DPI.
        _terminal.resize(
          cols: newCols,
          rows: newRows,
          cellWidthPx: (_paintState.metrics.cellWidth * dpr).round(),
          cellHeightPx: (_paintState.metrics.cellHeight * dpr).round(),
        );
        _onResize?.call(newCols, newRows);
      }
    } else if (_paintState.devicePixelRatio != dpr) {
      _paintState.devicePixelRatio = dpr;
    }

    _syncScrollLayout();

    // Grid changes invalidate every row's sprite slot layout. Atlas
    // rebinding invalidates atlas references inside the pipeline.
    if (gridChanged) _pipeline.markAllRowsDirty();

    if (gridChanged || atlasReconfigured) _markFrameDirty();

    _performingLayout = false;
  }

  void _applyTerminalThemeColors() {
    _terminal.foreground = _paintState.theme.foreground.toRgbColor();
    _terminal.background = _paintState.theme.background.toRgbColor();
    // Sentinel cursor colors (cellForeground/cellBackground) can't be
    // reported as a single RGB, so we only push a fixed color down to
    // libghostty; the flterm cursor painter resolves sentinels locally.
    _terminal.cursorColor = _paintState.theme.cursor.color?.fixedColor
        ?.toRgbColor();
    _terminal.palette = [
      for (var i = 0; i < 256; i++) _paintState.theme.palette[i].toRgbColor(),
    ];
  }

  bool _acquireAtlasForCurrentConfig({double? dpr, bool force = false}) {
    final config = AtlasConfig.fromTheme(
      theme: _paintState.theme,
      metrics: _paintState.metrics,
      devicePixelRatio: dpr ?? _currentDevicePixelRatio,
    );
    if (!force && config == _atlasHandle.config) return false;

    final previousHandle = _atlasHandle;
    _atlasHandle = _renderCache.acquireAtlas(config);
    _pipeline.bindAtlas(_atlasHandle.atlas);
    previousHandle.release();
    return true;
  }

  double get _currentDevicePixelRatio {
    return WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .devicePixelRatio;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _markFrameDirty() {
    _needsFrameSync = true;
    markNeedsPaint();
  }

  // #922 telemetry: emit a line the app can capture, NEVER collapsed. Used for
  // screen transitions and settle arm/fire — each is its own decision-point line.
  // No-op (and never builds the string) when nobody is listening.
  void _emitFrameDebug(String line) {
    final sink = onFrameDebug;
    if (sink == null) return;
    _flushFrameDebugRun();
    sink(line);
  }

  // #922 telemetry: emit a content-sync line, COLLAPSING identical consecutive
  // lines into a trailing ` (xN)` so a streaming burst doesn't flood the ring
  // (#805 / suppress-identical). Zero-rebuild and screen-transition lines never
  // route through here, so the stale-switch signal is never merged away.
  void _emitFrameDebugCollapsed(String line) {
    final sink = onFrameDebug;
    if (sink == null) return;
    if (line == _lastFrameDebugLine) {
      _lastFrameDebugCount++;
      return;
    }
    _flushFrameDebugRun();
    _lastFrameDebugLine = line;
    _lastFrameDebugCount = 1;
    sink(line);
  }

  // Flush a pending collapsed run as ` (xN)` (N>1) before a non-collapsed line.
  void _flushFrameDebugRun() {
    final sink = onFrameDebug;
    if (sink == null) {
      _lastFrameDebugLine = null;
      _lastFrameDebugCount = 0;
      return;
    }
    if (_lastFrameDebugLine != null && _lastFrameDebugCount > 1) {
      sink('${_lastFrameDebugLine!} (x$_lastFrameDebugCount)');
    }
    _lastFrameDebugLine = null;
    _lastFrameDebugCount = 0;
  }

  // #922 telemetry: compose + route the per-content-sync line from the facts the
  // pipeline's last sync recorded. A ZERO-rebuild sync is emitted verbatim (never
  // collapsed) with the FULL diagnostic field set — it is the stale-switch tell.
  // A sync that DID rebuild emits the collapsed cadence summary.
  void _emitFrameDebugLine() {
    final rebuilt = _pipeline.debugRowsRebuiltLastSync;
    final screen = _terminal.activeScreen.name;
    if (rebuilt == 0) {
      final dirty = _pipeline.debugLastSyncDirtyName;
      final markedAll = _lastNotifyMarkedAll ? 't' : 'f';
      final unsettled = _pipeline.debugLastSyncDamageUnsettled ? 't' : 'f';
      final det = _detectionActive ? 't' : 'f';
      _emitFrameDebug(
        'sync screen=$screen dirty=$dirty rebuilt=0 '
        'markedAll=$markedAll damageUnsettled=$unsettled detActive=$det',
      );
    } else {
      _emitFrameDebugCollapsed('sync screen=$screen rebuilt=$rebuilt');
    }
  }

  /// #918: arm the one-shot output settle tick. Cancels any pending timer and
  /// reschedules, so a streaming burst of notifies coalesces into a SINGLE forced
  /// frame fired once the output quiets for [kOutputSettle]. Disarms on fire. Called
  /// ONLY from `_onTerminalChanged`, so an idle terminal never arms it (#805 guard).
  void _armOutputSettleTick() {
    final wasArmed = _outputSettleTimer != null;
    _outputSettleTimer?.cancel();
    _outputSettleTimer = _scheduleSettleTimer(kOutputSettle, _onOutputSettled);
    // #922 telemetry: emit only on the LEADING arm (a re-arm during a burst is a
    // coalesce, not a new event — collapsing it keeps the capture readable).
    if (!wasArmed) _emitFrameDebug('settle arm');
  }

  /// #918: the output settle tick fired — force ONE full frame and disarm. The
  /// `markAllRowsDirty` re-reads the visible grid so the latest snapshot reaches the
  /// screen even when libghostty's damage was consumed by a prior frame.
  void _onOutputSettled() {
    _outputSettleTimer = null;
    _emitFrameDebug('settle fire');
    forceRepaint();
  }

  void _onRenderObserverChanged() {
    final previousSelection = _paintState.selection;
    final newSelection = _renderObserver.selection;
    _paintState.selection = newSelection;
    final previousHighlights = _paintState.highlights;
    final newHighlights = _renderObserver.highlights;
    _paintState.highlights = newHighlights;
    _paintState.cursorFocused = _renderObserver.hasFocus;
    if (previousSelection != newSelection) {
      final viewportOffset = _terminal.scrollbar.offset;
      _pipeline.markSelectionRowsDirty(
        previousSelection,
        viewportOffset: viewportOffset,
      );
      _pipeline.markSelectionRowsDirty(
        newSelection,
        viewportOffset: viewportOffset,
      );
    }
    if (!identical(previousHighlights, newHighlights)) {
      final viewportOffset = _terminal.scrollbar.offset;
      _pipeline.markHighlightRowsDirty(
        previousHighlights,
        viewportOffset: viewportOffset,
      );
      _pipeline.markHighlightRowsDirty(
        newHighlights,
        viewportOffset: viewportOffset,
      );
    }
    _pipeline.refreshCursorGlyph();
    markNeedsPaint();
  }

  void _onScroll() {
    if (_performingLayout) return;
    if (_paintState.rows == 0 || _paintState.metrics.cellHeight <= 0) return;

    final scrollbar = _terminal.scrollbar;
    final scrollbackLen = scrollbar.total - scrollbar.visible;
    if (scrollbackLen <= 0) return;

    final cellHeight = _paintState.metrics.cellHeight;
    final maxExtent = scrollbackLen * cellHeight;
    final pixels = _offset.pixels.clamp(0.0, maxExtent);

    _stickToBottom = maxExtent <= 0 || pixels >= maxExtent - cellHeight;

    final targetOffset = (pixels / cellHeight).floor();
    final delta = targetOffset - scrollbar.offset;

    if (delta == 0) return;

    _terminal.scrollViewport(delta);
    _markFrameDirty();
  }

  // Handles terminal change notifications. See the inline #887/#898 notes for
  // why the glyph dirty-mark is unconditional and why only `markNeedsLayout` is
  // gated on `_performingLayout`.
  void _onTerminalChanged() {
    if (_paintState.rows == 0) return;
    _debugContentNotifyCount++;

    final scrollbackChanged = _terminal.scrollbackRows != _lastScrollbackRows;

    // #898: the GLYPH dirty-mark is UNCONDITIONAL — ANY content change marks
    // this box needs-paint AND `_needsFrameSync` (so the next paint re-snapshots
    // the cells). We deliberately do NOT enumerate triggers (scrollback-grew /
    // size-change / in-place alt-screen redraw): the rendered grid is gated on
    // `_needsFrameSync` + the needs-PAINT set, so a notify that does not mark
    // BOTH leaves the glyphs stale until an unrelated frame forces a paint. That
    // was the #887 class (the scrollback-grew branch only re-laid out) and the
    // #898 class — a tmux window switch is an IN-PLACE alt-screen redraw (no
    // scrollback growth, no grid resize); when its notify fired while this box
    // was mid-`performLayout` the old `if (_performingLayout) return;` guard
    // DROPPED it entirely, so the new window's glyphs never repainted (the
    // intermittent stale display).
    //
    // `markNeedsPaint()` is SAFE while `_performingLayout` is true: layout runs
    // BEFORE paint in the frame pipeline, so setting the needs-paint flag here
    // simply schedules this box's paint for the SAME frame — it is not dropped.
    // (libghostty fires this listener synchronously from `performLayout` via
    // `Terminal.resize` / `_syncScrollLayout`'s viewport scroll.) Always do it.
    _markFrameDirty();

    // #900 (STRUCTURAL, supersedes the #887/#898 per-trigger patches): on the
    // ALTERNATE screen, force a FULL re-read of the visible grid on every
    // content-change notify, instead of trusting libghostty's single-consumption
    // per-row damage.
    //
    // ROOT of the "every OTHER switch repaints" alternation: the partial-build
    // path (`TerminalFrameBuilder.sync` → `_build(.partial)`) re-reads only the
    // rows libghostty's `RenderState.update` reports DAMAGED, and `update`
    // CONSUMES (clears) that damage as it reads it. The render box fires multiple
    // paints per tmux window switch (cursor blink, scroll/offset correction, the
    // atlas `onImageReady` repaint, the #803 painted-offset post-frame notify).
    // When an EARLIER paint's `update` consumes the switch's row damage before
    // the build that actually reaches the screen — or when a second `update`
    // straddles the in-place redraw — the next switch's `update` can read as
    // CLEAN (no NEW damage since the consumed one), so its build re-reads NO
    // rows and the grid stays on the previous window. The damage is repopulated
    // only every other cycle, which is the strict A/B/A/B alternation. This is
    // single-consumption damage feeding a partial build that has no flterm-side
    // guarantee the consuming `update` is the one that paints.
    //
    // The fix DECOUPLES alt-screen redraw correctness from that damage entirely:
    // `markAllRowsDirty()` makes `_dirtyRows.anyDirty` true, so the build runs and
    // re-reads the FULL visible grid from the CURRENT `RenderState` snapshot even
    // when `update` returns `.clean` because a prior frame already consumed the
    // per-row damage. The alternate screen has NO scrollback, so a full re-read is
    // bounded to the visible rows — what a native terminal does for a full-screen
    // app redraw. This is scoped to the alternate screen, so #805's primary-screen
    // streaming-output perf path (which relies on partial per-row rebuilds during
    // scrollback growth) is untouched.
    //
    // #921: the SAME single-consumption damage race also breaks the PRIMARY
    // screen — but ONLY when structured-text DETECTION is active. Detection adds
    // a SECOND `RenderState` handle (the controller's), registered BEFORE this
    // render box, that consumes the shared terminal's per-row damage on the same
    // synchronous notify. With detection OFF nothing competes, so the partial
    // path works and the #805 streaming perf path is untouched. So widen the
    // full-re-read gate to the primary screen ONLY while detection is active: a
    // full VISIBLE-grid re-read (bounded — no scrollback walk), fired only on a
    // content notify, makes the paint immune to the detection handle's consume.
    final markedAll = _terminal.activeScreen == .alternate || _detectionActive;
    if (markedAll) {
      _pipeline.markAllRowsDirty();
    }

    // #922 telemetry: remember whether THIS notify applied markAllRowsDirty so the
    // paint-time sync's emitted line reflects the decision (sync runs later). And
    // emit a primary↔alternate TRANSITION line — a tmux window switch / full-screen
    // app enter/exit — which is the boundary the stale-switch race lives at.
    _lastNotifyMarkedAll = markedAll;
    final screen = _terminal.activeScreen;
    final previousScreen = _lastObservedScreen;
    if (previousScreen != null && previousScreen != screen) {
      _emitFrameDebug('screen ${previousScreen.name}->${screen.name}');
    }
    _lastObservedScreen = screen;

    // #918 OUTPUT SETTLE TICK: a content-change notify is driven by PTY output (or
    // a local edit). Arm a one-shot timer that forces ONE full frame ~80ms after the
    // burst quiets, guaranteeing the snapshot reaches the screen even if the normal
    // damage/frame path dropped it. Re-arming on each notify coalesces a streaming
    // burst into a single trailing tick. It fires ONCE then disarms (see `_fire`),
    // and is armed ONLY from this notify — so when idle (no output, no input) it
    // never schedules or fires: zero repaints (the #805 battery perf guard).
    _armOutputSettleTick();

    // `markNeedsLayout()` is the ONLY part that is illegal during layout (it
    // throws "called during layout"), and it is redundant then anyway — we are
    // already in a layout pass that will recompute scroll extents. So request a
    // follow-up layout for a scrollback-length change ONLY when not mid-layout.
    if (scrollbackChanged && !_performingLayout) markNeedsLayout();
  }

  // Maintains scroll position and content dimensions.
  //
  // "Stick to bottom" keeps the viewport pinned to the latest output,
  // which is the normal mode when the user hasn't scrolled up. Once the
  // user scrolls away from the bottom, new output no longer forces the
  // viewport down. Stick-to-bottom re-engages when the user scrolls
  // back to within one cell of the bottom edge.
  void _syncScrollLayout() {
    _offset.applyViewportDimension(size.height);

    if (_terminal.activeScreen == .alternate) {
      _offset.applyContentDimensions(0, 0);
      _lastScrollbackRows = 0;
      _stickToBottom = true;
      return;
    }

    final scrollbar = _terminal.scrollbar;
    final scrollbackLen = scrollbar.total - scrollbar.visible;
    final cellHeight = _paintState.metrics.cellHeight;
    final maxExtent = scrollbackLen * cellHeight;

    // Detect if the terminal was scrolled to bottom externally.
    if (!_stickToBottom &&
        scrollbackLen > 0 &&
        scrollbar.offset >= scrollbackLen) {
      _stickToBottom = true;
    }

    if (_stickToBottom && maxExtent > 0) {
      final correction = maxExtent - _offset.pixels;
      if (correction.abs() > 0.01) _offset.correctBy(correction);
      if (scrollbar.offset < scrollbackLen) _terminal.scrollToBottom();
    }
    _offset.applyContentDimensions(0, maxExtent);
    _lastScrollbackRows = scrollbackLen;
    _stickToBottom = maxExtent <= 0 || _offset.pixels >= maxExtent - cellHeight;
  }

  // Syncs terminal state into paint-ready frame buffers.
  void _syncFrameState() {
    if (_paintState.rows == 0) return;

    final terminalDirty = _needsFrameSync;
    _needsFrameSync = false;
    if (terminalDirty) _debugFrameSyncCount++;
    // #918: this frame consumed any coalesced force-repaint; a fresh input after
    // this paint may force again (once per frame).
    _forceCoalesced = false;
    _pipeline.sync(
      _terminal,
      terminalDirty: terminalDirty,
      preeditText: _preeditText,
    );
    // #922 telemetry: emit ONE capturable line per CONTENT sync (the
    // `terminalDirty` syncs — a PTY/notify-driven re-snapshot, the class the
    // stale-switch race lives in). A re-read of ZERO rows while markAllRowsDirty
    // was in effect is the smoking gun (the build ran but re-emitted nothing →
    // the paint kept the old window). Zero-rebuild lines emit verbatim; rebuilt
    // syncs collapse into a ` (xN)` run so a streaming burst stays readable.
    // Cheap string + ring append; no markNeedsPaint, so logging never alters the
    // paint/dirty/sync timing.
    if (onFrameDebug != null && terminalDirty) {
      _emitFrameDebugLine();
    }
    // #803: hand the offset this frame painted the text with back to the
    // controller so the widget-layer decorator (URL bubble) resolves its anchor
    // rects against the SAME frame-synced offset the HighlightPainter uses,
    // instead of the live scrollbar.offset. The controller defers the resulting
    // notify to post-frame, so the decorator repaints in lockstep with the
    // glyphs and the markup no longer dances ahead during a tmux-redraw scroll.
    _renderObserver.reportPaintedViewportOffset(_paintState.viewportOffset);
  }
}

extension on Color {
  RgbColor toRgbColor() => RgbColor(
    (r * 255.0).round().clamp(0, 255),
    (g * 255.0).round().clamp(0, 255),
    (b * 255.0).round().clamp(0, 255),
  );
}
