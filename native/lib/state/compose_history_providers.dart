// Per-session compose history ring (#797) — PWA parity with src/modules/ime.ts
// `_commitHistory`.
//
// WHY A PROVIDER (not widget State): the compose bar CLOSES after every
// commit/submit (#614), which destroys its `State`. The owner's need — "I write
// a lot and then it gets lost sometimes" — is precisely that sent commands must
// survive that open/close cycle so they can be recalled later. So the history
// LIST lives here, keyed by session id, OUTSIDE the widget. The browse CURSOR
// (index + stash) stays ephemeral in the compose bar's State, mirroring the
// PWA's module-level `_historyIndex`/`_historyStash` which reset per browse.
//
// PER-SESSION ISOLATION (memory feedback_feature_scoping_and_isolation_tests):
// each session id owns its own ring. Pushing to one session never changes
// another. A session not yet in the map is treated as empty; the first push
// materializes its entry.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Max entries retained per session — mirrors the PWA `HISTORY_MAX` (20). The
/// oldest entry is evicted once the ring is full.
const int kComposeHistoryMax = 20;

/// Per-session ring of sent compose-bar commands. The map is keyed by session
/// id; each value is the ordered history (oldest first, newest last).
class ComposeHistoryNotifier extends Notifier<Map<String, List<String>>> {
  @override
  Map<String, List<String>> build() => const {};

  /// The history for [sessionId], oldest first. Empty for an unknown session.
  List<String> historyOf(String sessionId) => state[sessionId] ?? const [];

  /// Record [text] as the newest entry for [sessionId]. Mirrors the PWA
  /// `_recordHistory`: ignores empty text, de-duplicates a consecutive
  /// identical entry, and caps the ring at [kComposeHistoryMax] (evicting the
  /// oldest). Touches ONLY this session's entry — sibling sessions are
  /// untouched (per-session isolation, #797).
  void push(String sessionId, String text) {
    if (text.isEmpty) return;
    final current = state[sessionId] ?? const <String>[];
    // Deduplicate consecutive identical entries.
    if (current.isNotEmpty && current.last == text) return;
    final next = [...current, text];
    if (next.length > kComposeHistoryMax) {
      next.removeRange(0, next.length - kComposeHistoryMax);
    }
    state = {...state, sessionId: next};
  }
}

final composeHistoryProvider =
    NotifierProvider<ComposeHistoryNotifier, Map<String, List<String>>>(
      ComposeHistoryNotifier.new,
    );
