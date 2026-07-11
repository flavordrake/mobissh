/// Structured-text detection hot-path counters (#1044).
///
/// The scroll-lag investigation needed the scan/prune cost made OBSERVABLE:
/// during a fling the controller used to re-validate every live anchor
/// synchronously per scroll tick and re-scan a ~440-row window on every
/// settle, all through per-cell FFI reads — and none of it showed up anywhere
/// a test or a bug report could read. These monotonic counters mirror the
/// render box's `debugContentNotifyCount`/`debugPaintCount` idiom for the
/// DETECTION pipeline, so the replay perf suite can assert "pure scroll = 0
/// scans" and the app can ride the snapshot into bug-report telemetry.
///
/// Counters only — no timing control flow. Incremented by
/// `TerminalControllerImpl`'s rescan/prune paths; reset belongs to tests.
class DetectionScanStats {
  /// `_rescanDetections` passes that actually READ cells (a cache-invalid
  /// full-window scan or a partial dirty/reveal-region scan).
  int rescans = 0;

  /// Absolute rows covered by those rescan reads (post wrap-extension).
  int rescanRows = 0;

  /// Microseconds spent inside `StructuredTextScanner.scan` during rescans.
  int rescanMicros = 0;

  /// Rescan passes answered ENTIRELY from the row cache — the viewport moved
  /// over already-scanned rows and no content changed, so zero cells were
  /// read and zero regexes ran (#1044's "pure scroll costs zero scan work").
  int rescanCacheHits = 0;

  /// Rescans deferred because the viewport was actively scrolling
  /// (`isScrolling`); the settle pass runs exactly one reconcile instead.
  int rescansDeferredScrolling = 0;

  /// `_pruneStaleDetections` passes that had live matches to consider.
  int prunes = 0;

  /// Per-match `_scanWindow` re-validations the prune performed (each is a
  /// bounded cell re-read + full pattern pass over the match's rows).
  int pruneWindowScans = 0;

  /// Microseconds spent inside prune `_scanWindow` scans.
  int pruneMicros = 0;

  /// Matches the prune kept WITHOUT a re-read because their rows sit fully
  /// in immutable scrollback (below the active grid) in an unshifted frame.
  int pruneSkippedImmutable = 0;

  /// Missed matches the prune atomically RELOCATED to their new grid rows
  /// (an in-place TUI repaint moved the line) instead of evict-now /
  /// rediscover-after-the-debounce — the #1046 chip-blink killer.
  int pruneRelocated = 0;

  /// Reconciles that preserved an existing match INSTANCE for identical
  /// fresh content (#1046 anchor-identity stability).
  int matchesReused = 0;

  /// Reconciles whose final match set was element-wise identical to the live
  /// set — no reassignment, no decoration notify (the #1046 churn killer).
  int notifiesSuppressed = 0;

  /// #1060: anchor-bakes where a live match's behind-glyph WASH was WITHHELD
  /// because the anchor's payload is currently unconfirmed on the grid (its
  /// miss-grace timer is running). Proves the runtime path that keeps a stale
  /// wash from floating over moved/blank cells on a churning TUI: >0 during an
  /// in-place repaint burst, 0 on a stable shell. The anchor itself stays live
  /// (gutter chip + hit-test) — only its wash waits for re-confirmation.
  int washSuppressedForGrace = 0;

  /// #1062: painted-offset reports where the detection WASH was HIDDEN because
  /// the viewport was actively scrolling (a wash was live AND `isScrolling`).
  /// Proves the hide-on-scroll path fired: >0 during a scroll/fling over
  /// detected content, 0 on a stationary screen. The wash's baked absolute rows
  /// can drift off their tokens mid-scroll (the rescan/relocate is deferred for
  /// perf, #1044), so rather than paint a pinned/stale band the render layer
  /// hides it and re-shows on settle at the correct offset (the #988 stance).
  int washHiddenForScroll = 0;

  /// One flat map for telemetry / test assertions.
  Map<String, int> snapshot() => <String, int>{
        'rescans': rescans,
        'rescanRows': rescanRows,
        'rescanMicros': rescanMicros,
        'rescanCacheHits': rescanCacheHits,
        'rescansDeferredScrolling': rescansDeferredScrolling,
        'prunes': prunes,
        'pruneWindowScans': pruneWindowScans,
        'pruneMicros': pruneMicros,
        'pruneSkippedImmutable': pruneSkippedImmutable,
        'pruneRelocated': pruneRelocated,
        'matchesReused': matchesReused,
        'notifiesSuppressed': notifiesSuppressed,
        'washSuppressedForGrace': washSuppressedForGrace,
        'washHiddenForScroll': washHiddenForScroll,
      };

  /// Zero every counter (tests bracket a measured phase with this).
  void reset() {
    rescans = 0;
    rescanRows = 0;
    rescanMicros = 0;
    rescanCacheHits = 0;
    rescansDeferredScrolling = 0;
    prunes = 0;
    pruneWindowScans = 0;
    pruneMicros = 0;
    pruneSkippedImmutable = 0;
    pruneRelocated = 0;
    matchesReused = 0;
    notifiesSuppressed = 0;
    washSuppressedForGrace = 0;
    washHiddenForScroll = 0;
  }
}
