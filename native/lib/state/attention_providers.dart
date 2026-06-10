// Attention focus router provider (#840, Slice 2).
//
// Wires the pure [AttentionFocusRouter] to the live UI: the FFT-backed
// [PendingFocusBridge] (process-death-surviving), `sessionsProvider.setActive`,
// session existence, and PTY input for the guarded tmux select-window.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/attention_focus_router.dart';
import '../services/attention_notifier_fln.dart';
import '../services/session_attention_notification.dart';
import 'sessions.dart';

/// Builds the [AttentionFocusRouter] bound to the live session collection.
///
/// `isTmux` heuristic: the `(win N)` source-window hint is emitted by the
/// owner's tmux `alert-bell` hook — a non-tmux shell does not produce it — so a
/// parsed hint is itself a strong tmux signal. We therefore treat any session
/// that reached the router with a hint as a tmux client. (A precise per-session
/// tmux flag from the DA2 handshake is a future refinement; the navigation is
/// device-gated + best-effort and skips silently on a miss either way.)
final attentionFocusRouterProvider = Provider<AttentionFocusRouter>((ref) {
  final bridge = PendingFocusBridge(const FftKeyValueStore());
  return AttentionFocusRouter(
    bridge: bridge,
    setActive: (id) => ref.read(sessionsProvider.notifier).setActive(id),
    sessionExists: (id) =>
        ref.read(sessionsProvider).entries.any((e) => e.id == id),
    sendInput: (id, bytes) {
      for (final e in ref.read(sessionsProvider).entries) {
        if (e.id == id) {
          e.proxy.sendInput(Uint8List.fromList(bytes));
          return;
        }
      }
    },
    // #857: host fallback. When the tapped notification's EXACT sessionId is no
    // longer live (the host reconnected with a new `createdAtMs` nonce), route
    // to the MOST-RECENT live session for that host — never the previously-active
    // session to a different host. Session id format is
    // `host:port:user:createdAtMs`, so "most recent" = the largest trailing
    // createdAt segment among entries whose host matches.
    resolveLiveSessionForHost: (host) {
      String? bestId;
      int bestCreatedAt = -1;
      for (final e in ref.read(sessionsProvider).entries) {
        if (hostOfSessionId(e.id) != host) continue;
        final lastColon = e.id.lastIndexOf(':');
        final createdAt = lastColon < 0
            ? -1
            : (int.tryParse(e.id.substring(lastColon + 1)) ?? -1);
        if (createdAt >= bestCreatedAt) {
          bestCreatedAt = createdAt;
          bestId = e.id;
        }
      }
      return bestId;
    },
    // See doc above: a parsed (win N) hint implies the owner's tmux setup.
    isTmux: (_) => true,
    // #710: open an explicitly-signalled URL from the tapped notification in the
    // system browser. Same idiom as url_action_overlay's _defaultOpen. The
    // router guards to well-formed http(s) and swallows launch errors.
    openUrl: (url) async {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    },
  );
});
