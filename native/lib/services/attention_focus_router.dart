// Attention focus router (#840, Slice 2).
//
// Consumes a pending focus recorded by a tapped attention notification (via
// [PendingFocusBridge]) and routes the UI to the originating session:
//
//   1. `setActive(sessionId)` — switch the front-most tab (no-op if the session
//      no longer exists; the router tolerates a stale id).
//   2. GUARDED enhancement: if the payload parsed a `(win N)` source-window hint
//      AND that session is a tmux client, send a `select-window N` over the live
//      PTY using the same default-prefix select-window sequence the terminal's
//      wheel/window-select infra relies on. Defensive: no hint → skip silently.
//
// The platform/UI wiring (which sessionId is valid, how to send PTY bytes, how
// to detect tmux) is injected so this class is unit-testable without Flutter.

import 'session_attention_notification.dart';
import 'tmux_window_select.dart';

/// Routes a pending notification-tap focus to the right session + window.
class AttentionFocusRouter {
  AttentionFocusRouter({
    required PendingFocusBridge bridge,
    required void Function(String sessionId) setActive,
    required bool Function(String sessionId) sessionExists,
    required void Function(String sessionId, List<int> bytes) sendInput,
    bool Function(String sessionId)? isTmux,
  }) : _bridge = bridge,
       _setActive = setActive,
       _sessionExists = sessionExists,
       _sendInput = sendInput,
       _isTmux = isTmux;

  // ignore_for_file: prefer_initializing_formals
  final PendingFocusBridge _bridge;
  final void Function(String sessionId) _setActive;
  final bool Function(String sessionId) _sessionExists;
  final void Function(String sessionId, List<int> bytes) _sendInput;
  final bool Function(String sessionId)? _isTmux;

  /// One-shot consume of any pending focus. Safe to call on init (cold start)
  /// AND resume (warm) — `takePending` clears the record so a later resume
  /// doesn't re-focus the same session. Returns the focused sessionId, or null
  /// when there was nothing pending (or the session no longer exists).
  Future<String?> consumePending() async {
    final pending = await _bridge.takePending();
    final sid = pending.sessionId;
    if (sid == null) return null;
    if (!_sessionExists(sid)) return null;

    _setActive(sid);

    // GUARDED source-window navigation (device-gated, may be flaky under
    // multi-client tmux). Only when a window hint parsed AND the session is a
    // tmux client. Absent hint or non-tmux → skip silently.
    final win = pending.sourceWindow;
    if (win != null && (_isTmux?.call(sid) ?? false)) {
      _sendInput(sid, tmuxSelectWindowSequence(win));
    }
    return sid;
  }
}
