// Paint-stack boundary counters (paint replay harness).
//
// Owner report 2026-07-08T00-51-01 ("paint not happening", plain PowerShell,
// no tmux): the byte trace PROVED bytes reached the UI and the repaint
// telemetry showed `sync rebuilt=34` while the glass stayed on the pre-typing
// screen. To make the NEXT such report name the broken layer, every boundary
// of the write→damage→paint pipeline gets a monotonic counter:
//
//   bytesInChunks / bytesInTotal  — proxy.output chunks written to the
//                                   controller (the single write seam)
//   writeErrors                   — controller.write threw (previously
//                                   swallowed silently by the defensive catch)
//   contentNotifies               — terminal content-change notifies the render
//                                   box observed (flterm debugContentNotifyCount)
//   paints                        — render box paint() executions
//   frameSyncs                    — paint-time syncs with terminal-dirty content
//   lastSyncRebuiltRows           — rows the last sync re-emitted
//   forceRepaints                 — #918 forced re-snapshots
//
// The snapshot rides in the bug-report payload (feedback_overlay) and is read
// directly by the on-emulator paint replay test
// (integration_test/paint_replay_test.dart). Mirrors the
// session_byte_recorder registry pattern: keyed by session id + an active
// pointer, no Riverpod dependency for the above-the-Navigator overlay.

/// Per-session paint-stack counters. The app-side fields are incremented by
/// the ghostty view's output listener; the render-box fields are read live via
/// [boxProbe] (wired by the view, since the box is recreated on remount).
class GhosttyPaintStats {
  /// Chunks delivered to `controller.write` via the proxy output listener.
  int bytesInChunks = 0;

  /// Total bytes across those chunks.
  int bytesInTotal = 0;

  /// `controller.write(bytes)` threw. Before this counter the defensive catch
  /// swallowed the error with NO trace — a broken write path looked identical
  /// to a healthy one.
  int writeErrors = 0;

  /// Live probe into the flterm render box's boundary counters
  /// (contentNotifies / paints / frameSyncs / lastSyncRebuiltRows /
  /// forceRepaints). Set by the view whenever it can resolve its render box;
  /// null (→ fields omitted) when the box is gone.
  Map<String, Object?> Function()? boxProbe;

  /// One flat map for the bug-report payload / test assertions.
  Map<String, Object?> snapshot() {
    return <String, Object?>{
      'bytesInChunks': bytesInChunks,
      'bytesInTotal': bytesInTotal,
      'writeErrors': writeErrors,
      ...?boxProbe?.call(),
    };
  }
}

final Map<String, GhosttyPaintStats> _stats = <String, GhosttyPaintStats>{};
String? _activeSessionId;

/// Register (or fetch) the stats for [sessionId]. Idempotent.
GhosttyPaintStats registerPaintStats(String sessionId) {
  return _stats.putIfAbsent(sessionId, GhosttyPaintStats.new);
}

/// The stats for [sessionId], or null if none registered.
GhosttyPaintStats? paintStatsFor(String sessionId) => _stats[sessionId];

/// Drop the stats for [sessionId] (session teardown).
void unregisterPaintStats(String sessionId) {
  _stats.remove(sessionId);
  if (_activeSessionId == sessionId) _activeSessionId = null;
}

/// Mark [sessionId] as the active (on-screen) session whose stats the feedback
/// overlay snapshots. Pass null when no terminal is foregrounded.
void setActivePaintStats(String? sessionId) {
  _activeSessionId = sessionId;
}

/// Paint-stack snapshot of the active session, or null when none is active.
Map<String, Object?>? activePaintStatsSnapshot() {
  final id = _activeSessionId;
  if (id == null) return null;
  return _stats[id]?.snapshot();
}

/// Clear the whole registry + active pointer (tests).
void clearAllPaintStats() {
  _stats.clear();
  _activeSessionId = null;
}
