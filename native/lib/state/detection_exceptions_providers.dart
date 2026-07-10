// Detection exceptions provider (#995) — the session-facing side of the
// "Not a URL" / "Not a file" reports.
//
// Holds the hydrated exception list and answers the HOT question — "is this
// payload suppressed?" — with a per-family hash-set lookup, rebuilt only when
// the list changes. The lookup runs inside the #990 visibility gate
// (`_isPayloadVisible` in ghostty_terminal_view.dart), which is consulted on
// every gutter/bubble regroup and every tap hit-test, so it must be O(1).
//
// State is the exception LIST (Settings renders it; the terminal view watches
// it so an add/remove immediately regroups the affordance layers). Suppression
// is GLOBAL (v1); records carry host for later per-profile scoping.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/detection_exceptions_store.dart';

class DetectionExceptionsNotifier
    extends StateNotifier<List<DetectionException>> {
  DetectionExceptionsNotifier({DetectionExceptionsStore? store})
    : _store = store ?? DetectionExceptionsStore(),
      super(const <DetectionException>[]) {
    ready = _hydrate();
  }

  final DetectionExceptionsStore _store;

  /// Completes when the persisted corpus has hydrated (tests await this; the
  /// UI just watches state — the empty default is correct pre-hydrate).
  late final Future<void> ready;

  /// family → set of suppressed matched texts. Rebuilt on every state change
  /// so [isSuppressed] stays a pure hash lookup.
  Map<String, Set<String>> _index = const <String, Set<String>>{};

  void _setState(List<DetectionException> entries) {
    state = List<DetectionException>.unmodifiable(entries);
    final index = <String, Set<String>>{};
    for (final e in entries) {
      (index[e.family] ??= <String>{}).add(e.matchedText);
    }
    _index = index;
  }

  Future<void> _hydrate() async {
    try {
      _setState(await _store.load());
    } catch (_) {
      // best-effort; keep the empty default if prefs are unavailable (tests).
    }
  }

  /// True when [payload]'s exact text was reported as a false positive for
  /// [patternId]'s family. O(1) hash-set lookup — safe on the per-anchor
  /// visibility path.
  bool isSuppressed(String patternId, String payload) =>
      _index[detectionExceptionFamily(patternId)]?.contains(payload) ?? false;

  /// Persist a new false-positive report and suppress it immediately.
  /// [tsMs] defaults to now.
  Future<void> report({
    required String patternId,
    required String matchedText,
    String contextLine = '',
    String host = '',
    int? tsMs,
  }) async {
    final entries = await _store.add(
      DetectionException(
        matchedText: matchedText,
        patternId: patternId,
        contextLine: contextLine,
        host: host,
        tsMs: tsMs ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _setState(entries);
  }

  /// Remove [exception] — detection of its text returns immediately.
  Future<void> removeException(DetectionException exception) async {
    final entries = await _store.remove(
      patternId: exception.patternId,
      matchedText: exception.matchedText,
    );
    _setState(entries);
  }

  /// Prune EVERY exception in [patternId]'s family (#1031 slice 3: a deleted
  /// custom pattern takes its suppressions with it — the lab's delete confirm
  /// discloses the count first).
  Future<void> pruneFamily(String patternId) async {
    _setState(await _store.removeFamily(detectionExceptionFamily(patternId)));
  }
}

/// Global detection-exceptions provider (#995). The terminal view watches the
/// list (an add/remove regroups the affordance layers) and reads the notifier
/// for the hot [DetectionExceptionsNotifier.isSuppressed] lookup; Settings
/// renders + removes entries.
final detectionExceptionsProvider =
    StateNotifierProvider<
      DetectionExceptionsNotifier,
      List<DetectionException>
    >((ref) => DetectionExceptionsNotifier());
