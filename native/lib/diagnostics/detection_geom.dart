// #1072: detection wash GEOMETRY snapshot (frozen-bubble diagnostics).
//
// The "frozen bubble" symptom is a detection wash/gutter chip that stops
// tracking its token — it stays pinned to a viewport row while the content
// scrolls, or never repaints at all. Diagnosing it from a screenshot is
// guesswork: you can't see WHICH offset the painter used, whether the wash
// layer repainted between two captures, or whether the anchor's absolute row
// still maps to the row where the payload text actually is.
//
// This module captures, at bug-report time, a single `detectionGeom` object:
// the controller's live viewport offsets (screenViewportTop / scrollbarOffset /
// paintedViewportOffset), the render box's last-painted wash rows
// (drawnWashViewRows) and a monotonic paintTick (so a SECOND capture reveals
// whether the wash layer repaints at all), plus per-anchor rows — the absolute
// top row, the resolved gutter row, the row the painter WOULD draw the wash on
// (absTopRow - paintedViewportOffset), and the row where the payload text is
// ACTUALLY visible right now. When those diverge, the freeze is localized to a
// specific layer without another blind device build.
//
// ADDITIVE + read-only: the probe only reads accessors; it never mutates
// terminal, controller, or render state. Mirrors the paint_stats.dart registry
// pattern (session-keyed + an active pointer) so the above-the-Navigator
// feedback overlay can snapshot the on-screen session with no Riverpod scope.

/// Signature of the per-session geometry probe the terminal view installs. It
/// reads the live controller + render box and returns the assembled
/// `detectionGeom` map, or null when the view can't resolve them yet (before
/// first layout / after unmount).
typedef DetectionGeomProbe = Map<String, Object?>? Function();

final Map<String, DetectionGeomProbe> _probes = <String, DetectionGeomProbe>{};
String? _activeSessionId;

/// Register (or replace) the geometry probe for [sessionId]. The terminal view
/// wires this to a closure that reads its own controller + render box.
void registerDetectionGeom(String sessionId, DetectionGeomProbe probe) {
  _probes[sessionId] = probe;
}

/// Drop the geometry probe for [sessionId] (session teardown). Clears the active
/// pointer if it referenced this session.
void unregisterDetectionGeom(String sessionId) {
  _probes.remove(sessionId);
  if (_activeSessionId == sessionId) _activeSessionId = null;
}

/// Mark [sessionId] as the active (on-screen) session whose geometry the
/// feedback overlay snapshots. Pass null when no terminal is foregrounded.
void setActiveDetectionGeom(String? sessionId) {
  _activeSessionId = sessionId;
}

/// Detection-geometry snapshot of the active session, or null when none is
/// active or the probe can't resolve the controller/render box.
Map<String, Object?>? activeDetectionGeomSnapshot() {
  final id = _activeSessionId;
  if (id == null) return null;
  return _probes[id]?.call();
}

/// Clear the whole registry + active pointer (tests).
void clearAllDetectionGeom() {
  _probes.clear();
  _activeSessionId = null;
}
