// Riverpod surface for user-defined detection patterns (#1031 slice 3).
//
// [customPatternsProvider] holds the hydrated pattern list. The terminal view
// `ref.listen`s it for live pattern RE-registration (the slice-2 lexicon
// listen precedent) and the lab renders the MY PATTERNS zone from it.
//
// Hydrate AUTO-DISABLES any stored pattern whose regex no longer compiles
// (hand-edited / corrupt source): registration would skip it anyway, but the
// honest state is disabled-with-error, surfaced on its lab card — never a
// silent drop, never a crash.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/custom_patterns_store.dart';

/// Persisted user-defined patterns, creation order. Mutations go through the
/// notifier; the terminal registers enabled ones via ghosttyDetectionPatterns.
final customPatternsProvider =
    StateNotifierProvider<CustomPatternsNotifier, List<CustomPattern>>((ref) {
      return CustomPatternsNotifier();
    });

/// One pattern by id (null = unknown/deleted). Watch THIS from per-pattern UI
/// so sibling changes don't rebuild it.
final customPatternProvider = Provider.family<CustomPattern?, String>((
  ref,
  id,
) {
  for (final p in ref.watch(customPatternsProvider)) {
    if (p.id == id) return p;
  }
  return null;
});

/// Notifier over [CustomPatternsStore]. Best-effort hydrate/persist that
/// never throws when prefs are unavailable (widget tests without bindings) —
/// the DetectionStylesNotifier idiom.
class CustomPatternsNotifier extends StateNotifier<List<CustomPattern>> {
  CustomPatternsNotifier({CustomPatternsStore? store})
    : _store = store ?? CustomPatternsStore(),
      super(const <CustomPattern>[]) {
    ready = _hydrate();
  }

  final CustomPatternsStore _store;

  /// Completes when the persisted list has hydrated (tests await this; the
  /// UI just watches state — the empty default is correct pre-hydrate).
  late final Future<void> ready;

  Future<void> _hydrate() async {
    try {
      var stored = await _store.load();
      // Auto-disable on compile failure: a source that stopped compiling
      // can't register; persist the honest bit so every surface agrees.
      final broken = [
        for (final p in stored)
          if (p.enabled && compileCustomPatternRegex(p.source) == null) p.id,
      ];
      if (broken.isNotEmpty) {
        stored = [
          for (final p in stored)
            if (broken.contains(p.id)) p.copyWith(enabled: false) else p,
        ];
        await _store.saveAll(stored);
      }
      if (!mounted) return;
      state = List<CustomPattern>.unmodifiable(stored);
    } catch (_) {
      // best-effort; keep the empty default if prefs are unavailable.
    }
  }

  void _set(List<CustomPattern> next) {
    if (mounted) state = List<CustomPattern>.unmodifiable(next);
  }

  /// Create a pattern (id minted ONCE here — review change 5) and return it.
  Future<CustomPattern> create({
    required String name,
    required String source,
    String sampleLine = '',
  }) async {
    try {
      final created = await _store.add(
        name: name,
        source: source,
        sampleLine: sampleLine,
      );
      _set(await _store.load());
      return created;
    } catch (_) {
      // Prefs unavailable: still reflect the creation in memory.
      final created = CustomPattern(
        id: mintCustomPatternId(state.map((p) => p.id)),
        name: name,
        source: source,
        enabled: true,
        createdTs: DateTime.now().millisecondsSinceEpoch,
        sampleLine: sampleLine,
      );
      _set([...state, created]);
      return created;
    }
  }

  /// Edit [id]'s definition — the id NEVER changes (review change 5).
  Future<void> updatePattern(
    String id, {
    String? name,
    String? source,
    String? sampleLine,
  }) async {
    try {
      await _store.update(id, name: name, source: source, sampleLine: sampleLine);
      _set(await _store.load());
    } catch (_) {
      _set([
        for (final p in state)
          if (p.id == id)
            p.copyWith(name: name, source: source, sampleLine: sampleLine)
          else
            p,
      ]);
    }
  }

  /// Flip [id]'s enable bit.
  Future<void> setEnabled(String id, bool enabled) async {
    try {
      await _store.setEnabled(id, enabled);
      _set(await _store.load());
    } catch (_) {
      _set([
        for (final p in state)
          if (p.id == id) p.copyWith(enabled: enabled) else p,
      ]);
    }
  }

  /// Delete [id]. The CALLER owns the disclosed side effects (pruning the
  /// #995 exception family, dropping the style entry) — see the lab's
  /// delete confirm.
  Future<void> remove(String id) async {
    try {
      await _store.remove(id);
      _set(await _store.load());
    } catch (_) {
      _set([
        for (final p in state)
          if (p.id != id) p,
      ]);
    }
  }
}
