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
//   3. URL OPEN (#710): if the payload carries an explicitly-signalled
//      `http(s)://` URL (extracted from the attention signal text — the
//      "Build ready: https://…" dev-loop case), OPEN it via the injected
//      [openUrl] seam (production = `launchUrl(externalApplication)`). The tap
//      BOTH focuses the originating session AND opens the URL. Guarded to
//      well-formed http(s) only; launch errors are swallowed so a tap never
//      crashes.
//
// The platform/UI wiring (which sessionId is valid, how to send PTY bytes, how
// to detect tmux, how to open a URL) is injected so this class is unit-testable
// without Flutter.

import 'dart:developer' as developer;

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
    Future<void> Function(String url)? openUrl,
    String? Function(String host)? resolveLiveSessionForHost,
  }) : _bridge = bridge,
       _setActive = setActive,
       _sessionExists = sessionExists,
       _sendInput = sendInput,
       _isTmux = isTmux,
       _openUrl = openUrl,
       _resolveLiveSessionForHost = resolveLiveSessionForHost;

  // ignore_for_file: prefer_initializing_formals
  final PendingFocusBridge _bridge;
  final void Function(String sessionId) _setActive;
  final bool Function(String sessionId) _sessionExists;
  final void Function(String sessionId, List<int> bytes) _sendInput;
  final bool Function(String sessionId)? _isTmux;

  /// Host-fallback seam (#857). Given a HOST, returns the id of the most-recent
  /// LIVE session to that host, or null when the host has no live session.
  /// Used when the payload's EXACT sessionId is no longer live — the host
  /// reconnected with a fresh `createdAtMs` nonce, so the exact id is stale but
  /// the user still wants the tap to land on that host's session (NOT the
  /// previously-active, different-host session — the #857 bug). Null/unwired →
  /// no fallback (the router gives up on a stale id, as before).
  final String? Function(String host)? _resolveLiveSessionForHost;

  /// URL opener seam (#710), or null when URL-open is unwired (e.g. a test that
  /// only exercises focus routing). Production binds this to
  /// `launchUrl(externalApplication)`. Injected so the launch is unit-testable
  /// without a real browser.
  final Future<void> Function(String url)? _openUrl;

  /// One-shot consume of any pending focus. Safe to call on init (cold start)
  /// AND resume (warm) — `takePending` clears the record so a later resume
  /// doesn't re-focus the same session. Returns the focused sessionId, or null
  /// when there was nothing pending (or the session no longer exists).
  Future<String?> consumePending() async {
    final pending = await _bridge.takePending();
    final payloadSid = pending.sessionId;
    if (payloadSid == null) return null;
    final host = hostOfSessionId(payloadSid);

    // Resolve the session to actually focus (#857). Prefer the EXACT payload id
    // when it's still live. Otherwise fall back to the most-recent live session
    // for the SAME HOST — the host reconnected with a new `createdAtMs` nonce so
    // the exact id is stale, but the tap must still land on that host (NOT the
    // previously-active, different-host session — that was the #857 bug). Only
    // give up when the host has no live session.
    String? sid;
    String route;
    if (_sessionExists(payloadSid)) {
      sid = payloadSid;
      route = 'setActive';
    } else {
      final fallback = _resolveLiveSessionForHost?.call(host);
      if (fallback != null && _sessionExists(fallback)) {
        sid = fallback;
        route = 'host-fallback';
      } else {
        sid = null;
        route = 'none';
      }
    }

    developer.log(
      'focus: payload sid=$payloadSid host=$host → '
      '${sid == null ? 'none' : 'setActive(matched sid=$sid) | $route'}',
      name: 'attention',
    );

    if (sid == null) return null;

    _setActive(sid);

    // GUARDED source-window navigation (device-gated, may be flaky under
    // multi-client tmux). Only when a window hint parsed AND the session is a
    // tmux client. Targets the RESOLVED live session (#857), not the stale
    // payload id. Absent hint or non-tmux → skip silently.
    final win = pending.sourceWindow;
    if (win != null && (_isTmux?.call(sid) ?? false)) {
      _sendInput(sid, tmuxSelectWindowSequence(win));
    }

    // URL OPEN (#710): if the tapped notification carried an explicitly-signalled
    // http(s) URL, open it (in addition to focusing the session above). Guarded
    // to a well-formed http(s) URL; launch errors are swallowed so a tap never
    // crashes. Absent / malformed url or unwired opener → skip silently.
    final url = pending.url;
    final opener = _openUrl;
    if (url != null && opener != null && _isLaunchableHttpUrl(url)) {
      try {
        await opener(url);
      } catch (_) {
        // Best-effort: a failed launch must not break focus routing.
      }
    }
    return sid;
  }
}

/// Whether [url] is a well-formed absolute `http`/`https` URL safe to launch
/// (#710). Rejects other schemes (e.g. `javascript:`, `ftp:`) and unparseable
/// strings — only an explicitly web-addressable URL is ever launched.
bool _isLaunchableHttpUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (!uri.hasScheme || !uri.hasAuthority) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}
