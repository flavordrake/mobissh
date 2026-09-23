// #1135: frame-time + viewport telemetry (INSTRUMENTATION ONLY).
//
// Two owner reports ("several app stalls", then "a tap on the session menu
// takes about a second and a half") arrived with a bundle that had NO frame
// timing at all — `frameCount: 0` and a connect ring that, at the observed
// event rate, covers about two minutes. By the time the owner taps Feedback the
// onset of the stall is already evicted, so every read of those bundles is an
// inference. This module exists to make the NEXT report answer the question:
//
//   * WAS the UI actually janking, by how much, and how often?      → aggregates
//   * WHEN, and what did the app's geometry look like at that time? → worst list
//   * Under how much concurrent session load?                       → sessions
//
// Design notes that matter for a stall (learned from #921 / #1044 / #1071,
// where blind fixes cost two arcs):
//
//   - The aggregates are LIFETIME and histogram-backed, so a two-minute stall
//     can never push them out of a ring the way the connect log's 600 events
//     are pushed out. A ring that only holds the last N frames of a burst is
//     useless for exactly the case we are chasing.
//   - `addTimingsCallback` delivers timings AFTER the frames complete (batched),
//     so a stall is reported once the UI recovers — which is precisely when the
//     owner is able to tap Feedback. Timestamps are wall-clock at delivery, so
//     they are late by at most the batch, not by the stall.
//   - The viewport is read from the ENGINE VIEW (physicalSize / viewInsets /
//     viewPadding), never through MediaQuery. Subscribing a widget to
//     MediaQuery would ADD rebuilds — this file must not change what paints or
//     when. The app-believed side (the terminal's laid-out box + the cols×rows
//     it computed) is published from the layout seam that already computes it.
//
// Everything here is additive and read-only with respect to rendering: plain
// field writes on publish, map allocation only for frames that qualify as worst
// offenders or at snapshot time.

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Supplies the contextual snapshot (viewport + session load) stamped onto a
/// retained frame sample. Injected so the recorder is unit-testable with no
/// binding, no window and no sessions.
typedef FrameContextProbe = Map<String, Object?> Function();

/// Jank thresholds reported as counters. 16ms = a dropped 60Hz frame, 32ms =
/// two, 100ms = user-visible hitch (the class the owner describes as a stall).
const double kFrameOver16Ms = 16.0;
const double kFrameOver32Ms = 32.0;
const double kFrameOver100Ms = 100.0;

/// How recently a session must have delivered output to count as "streaming".
const Duration kStreamingWindow = Duration(seconds: 2);

/// Histogram resolution: one bucket per millisecond up to [_histOverflow],
/// which is the catch-all for >= 1000ms frames. 1001 ints is nothing, and it
/// makes p50/p95 exact to the millisecond over an unbounded frame count.
const int _histOverflow = 1000;

/// One retained frame (a worst offender), with the context captured at the
/// moment it was recorded — NOT at snapshot time, which would be minutes later
/// and geometrically unrelated.
class FrameSample {
  const FrameSample({
    required this.tsMs,
    required this.buildMs,
    required this.rasterMs,
    required this.context,
  });

  /// Wall clock (ms since epoch, UTC) at which the timing was delivered.
  final int tsMs;
  final double buildMs;
  final double rasterMs;
  final Map<String, Object?> context;

  double get totalMs => buildMs + rasterMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'tsMs': tsMs,
    'ts': DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true)
        .toIso8601String(),
    'buildMs': _round1(buildMs),
    'rasterMs': _round1(rasterMs),
    'totalMs': _round1(totalMs),
    ...context,
  };
}

double _round1(double v) => (v * 10).roundToDouble() / 10;

/// Bounded frame-timing recorder: lifetime aggregates + the worst frames seen.
class FrameStatsRecorder {
  FrameStatsRecorder({this.worstCapacity = 12, this.contextProbe});

  /// How many worst-offender samples to retain. Bounded by construction — the
  /// list is the evidence, not a log.
  final int worstCapacity;

  /// Supplies the viewport + session-load context stamped on a retained frame.
  final FrameContextProbe? contextProbe;

  final List<int> _hist = List<int>.filled(_histOverflow + 1, 0);
  final List<FrameSample> _worst = <FrameSample>[];

  int _count = 0;
  double _sumMs = 0;
  double _maxTotalMs = 0;
  double _maxBuildMs = 0;
  double _maxRasterMs = 0;
  int _over16 = 0;
  int _over32 = 0;
  int _over100 = 0;
  int _firstTsMs = 0;
  int _lastTsMs = 0;

  int get frameCount => _count;

  /// The retained worst frames, worst first.
  List<FrameSample> get worst => List<FrameSample>.unmodifiable(_worst);

  /// Record one completed frame. [tsMs] is wall clock at delivery.
  void recordFrame({
    required double buildMs,
    required double rasterMs,
    required int tsMs,
  }) {
    final total = buildMs + rasterMs;
    _count++;
    _sumMs += total;
    if (_firstTsMs == 0) _firstTsMs = tsMs;
    _lastTsMs = tsMs;
    if (total > _maxTotalMs) _maxTotalMs = total;
    if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
    if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;
    if (total >= kFrameOver16Ms) _over16++;
    if (total >= kFrameOver32Ms) _over32++;
    if (total >= kFrameOver100Ms) _over100++;

    var bucket = total.floor();
    if (bucket < 0) bucket = 0;
    if (bucket > _histOverflow) bucket = _histOverflow;
    _hist[bucket]++;

    // Only frames that actually make the worst list pay for a context probe —
    // the common (fast) frame costs a handful of scalar updates.
    if (worstCapacity <= 0) return;
    if (_worst.length >= worstCapacity && total <= _worst.last.totalMs) return;
    final sample = FrameSample(
      tsMs: tsMs,
      buildMs: buildMs,
      rasterMs: rasterMs,
      context: contextProbe?.call() ?? const <String, Object?>{},
    );
    var i = 0;
    while (i < _worst.length && _worst[i].totalMs >= total) {
      i++;
    }
    _worst.insert(i, sample);
    if (_worst.length > worstCapacity) _worst.removeLast();
  }

  /// Exact-to-the-millisecond percentile of total frame time. Returns 0 with no
  /// frames; returns the exact max for a percentile landing in the >=1000ms
  /// overflow bucket (where the histogram has no resolution but the max does).
  double percentileMs(double p) {
    if (_count == 0) return 0;
    final target = (_count * p).ceil().clamp(1, _count);
    var seen = 0;
    for (var b = 0; b <= _histOverflow; b++) {
      seen += _hist[b];
      if (seen >= target) {
        return b == _histOverflow ? _round1(_maxTotalMs) : b.toDouble();
      }
    }
    return _round1(_maxTotalMs);
  }

  /// The bug-report section. Flat scalars first so the whole shape is readable
  /// at a glance in the bundle JSON.
  Map<String, Object?> snapshot() => <String, Object?>{
    'frames': _count,
    'firstTsMs': _firstTsMs,
    'lastTsMs': _lastTsMs,
    'spanMs': _lastTsMs - _firstTsMs,
    'meanMs': _count == 0 ? 0.0 : _round1(_sumMs / _count),
    'p50Ms': percentileMs(0.50),
    'p95Ms': percentileMs(0.95),
    'maxMs': _round1(_maxTotalMs),
    'maxBuildMs': _round1(_maxBuildMs),
    'maxRasterMs': _round1(_maxRasterMs),
    'over16': _over16,
    'over32': _over32,
    'over100': _over100,
    'worst': <Map<String, Object?>>[for (final s in _worst) s.toJson()],
    // Context as of the capture itself — the viewport/session state the owner
    // is looking at while typing the report.
    'now': contextProbe?.call() ?? const <String, Object?>{},
  };

  /// One-line summary for the lifecycle/connect ring (mirrors the paint-stats
  /// stamp), so the numbers ride in EVERY report even where the structured
  /// section is not yet persisted downstream.
  String summaryLine() {
    final ctx = contextProbe?.call() ?? const <String, Object?>{};
    final view = ctx['viewport'];
    final sessions = ctx['sessions'];
    return 'frames=$_count span=${_lastTsMs - _firstTsMs}ms '
        'p50=${percentileMs(0.50)}ms p95=${percentileMs(0.95)}ms '
        'max=${_round1(_maxTotalMs)}ms '
        'over16=$_over16 over32=$_over32 over100=$_over100 '
        'worstKept=${_worst.length} '
        'viewport=$view sessions=$sessions';
  }

  /// Tests / a fresh process.
  void reset() {
    _hist.fillRange(0, _hist.length, 0);
    _worst.clear();
    _count = 0;
    _sumMs = 0;
    _maxTotalMs = 0;
    _maxBuildMs = 0;
    _maxRasterMs = 0;
    _over16 = 0;
    _over32 = 0;
    _over100 = 0;
    _firstTsMs = 0;
    _lastTsMs = 0;
  }
}

// ---------------------------------------------------------------------------
// Viewport truth + session load: publishers and the default context probe.
//
// Mirrors the paint_stats.dart registry pattern — plain globals, no Riverpod —
// so the above-the-Navigator feedback overlay can read them.
// ---------------------------------------------------------------------------

/// The geometry ONE terminal view laid out with, as the app computed it.
class TerminalGeometry {
  const TerminalGeometry({
    required this.boxWidth,
    required this.boxHeight,
    required this.cols,
    required this.rows,
    required this.tsMs,
  });

  final double boxWidth;
  final double boxHeight;
  final int cols;
  final int rows;
  final int tsMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'w': _round1(boxWidth),
    'h': _round1(boxHeight),
    'cols': cols,
    'rows': rows,
    'tsMs': tsMs,
  };
}

final Map<String, TerminalGeometry> _terminals = <String, TerminalGeometry>{};
final Map<String, int> _lastOutputMs = <String, int>{};
int _liveSessions = 0;
int _connectedSessions = 0;

/// Publish the box a terminal view was laid out with and the grid it computed
/// from it. Called from the LayoutBuilder seam that already has both. Plain map
/// write — no notify, no rebuild.
void recordTerminalViewport({
  required String sessionId,
  required double boxWidth,
  required double boxHeight,
  required int cols,
  required int rows,
  int? tsMs,
}) {
  _terminals[sessionId] = TerminalGeometry(
    boxWidth: boxWidth,
    boxHeight: boxHeight,
    cols: cols,
    rows: rows,
    tsMs: tsMs ?? DateTime.now().millisecondsSinceEpoch,
  );
}

/// Drop a terminal view's geometry (view disposed).
void clearTerminalViewport(String sessionId) {
  _terminals.remove(sessionId);
}

/// Publish the session counts. Called from the router build that already walks
/// the session list.
void recordSessionLoad({required int live, required int connected}) {
  _liveSessions = live;
  _connectedSessions = connected;
}

/// Note that [sessionId] delivered output. Bounded by the number of real
/// sessions; used to derive how many sessions are STREAMING concurrently,
/// which is the load axis both reports share.
void noteSessionOutput(String sessionId, {int? tsMs}) {
  _lastOutputMs[sessionId] = tsMs ?? DateTime.now().millisecondsSinceEpoch;
}

/// Drop a session's output timestamp (session closed).
void clearSessionOutput(String sessionId) {
  _lastOutputMs.remove(sessionId);
}

/// Session-load context: live/connected counts plus how many delivered output
/// inside [kStreamingWindow].
Map<String, Object?> sessionLoadSnapshot({int? nowMs}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  var streaming = 0;
  for (final ts in _lastOutputMs.values) {
    if (now - ts <= kStreamingWindow.inMilliseconds) streaming++;
  }
  return <String, Object?>{
    'live': _liveSessions,
    'connected': _connectedSessions,
    'streaming': streaming,
    'terminals': _terminals.length,
  };
}

/// Engine-view metrics — the REAL window. Logical pixels, so they compare
/// directly against the terminal box the app laid out. Read WITHOUT MediaQuery:
/// no widget gains a dependency, nothing rebuilds because of this telemetry.
/// Returns an empty map before the binding/view exists.
Map<String, Object?> windowViewportSnapshot() {
  try {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final view = dispatcher.implicitView ??
        (dispatcher.views.isEmpty ? null : dispatcher.views.first);
    if (view == null) return const <String, Object?>{};
    final dpr = view.devicePixelRatio == 0 ? 1.0 : view.devicePixelRatio;
    return <String, Object?>{
      'screenW': _round1(view.physicalSize.width / dpr),
      'screenH': _round1(view.physicalSize.height / dpr),
      'insetBottom': _round1(view.viewInsets.bottom / dpr),
      'paddingBottom': _round1(view.viewPadding.bottom / dpr),
      'paddingTop': _round1(view.viewPadding.top / dpr),
      'dpr': _round1(dpr),
    };
  } catch (_) {
    // Telemetry must never be the thing that throws.
    return const <String, Object?>{};
  }
}

/// The default context probe: real window metrics + every laid-out terminal box
/// + the session load. `terminals` is a LIST because a multi-session report has
/// several views laid out at once — and four views all re-laying-out is itself
/// the load signal the second report needs.
Map<String, Object?> defaultFrameContextProbe() => <String, Object?>{
  'viewport': windowViewportSnapshot(),
  'terminals': <Map<String, Object?>>[
    for (final entry in _terminals.entries)
      <String, Object?>{'sid': entry.key, ...entry.value.toJson()},
  ],
  'sessions': sessionLoadSnapshot(),
};

// ---------------------------------------------------------------------------
// Process-wide recorder + the timings hook.
// ---------------------------------------------------------------------------

/// The app's recorder. Lifetime aggregates, 12 worst frames retained.
final FrameStatsRecorder frameStats = FrameStatsRecorder(
  contextProbe: defaultFrameContextProbe,
);

bool _started = false;

/// Arm per-frame timing capture. Idempotent; safe to call before `runApp`.
void startFrameStats() {
  if (_started) return;
  _started = true;
  SchedulerBinding.instance.addTimingsCallback(_onTimings);
}

void _onTimings(List<FrameTiming> timings) {
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final t in timings) {
    frameStats.recordFrame(
      buildMs: t.buildDuration.inMicroseconds / 1000.0,
      rasterMs: t.rasterDuration.inMicroseconds / 1000.0,
      tsMs: now,
    );
  }
}

/// Frame-stats section for the bug-report bundle.
Map<String, Object?> frameStatsSnapshot() => frameStats.snapshot();

/// One-line frame-stats stamp for the lifecycle/connect ring.
String frameStatsLine() => frameStats.summaryLine();

/// Tests: clear the published geometry/session state as well as the counters.
void resetFrameStatsForTest() {
  frameStats.reset();
  _terminals.clear();
  _lastOutputMs.clear();
  _liveSessions = 0;
  _connectedSessions = 0;
}
