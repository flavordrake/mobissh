// Riverpod surface for the detection style overrides (#1031 slice 1).
//
// [detectionStylesProvider] holds the hydrated [DetectionStyles] value; the
// terminal view watches it and rebuilds its [DetectionStyleResolver] only when
// the stored overrides change — the detectionSettingsProvider caching idiom
// (resolve on change, never a prefs read per frame). Synchronous EMPTY default
// while prefs hydrate: empty = shipped visuals, so the first frame is always
// correct and a stored override re-applies on hydrate.
//
// [detectionPatternStyleProvider] is the cheap per-pattern family the lab UI
// (later slice) watches: one pattern's row rebuilds only when ITS override
// changes, not on siblings.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/detection_styles_store.dart';

/// Persisted per-pattern style overrides. Mutations go through the notifier;
/// painters consume the value via the terminal view's resolver.
final detectionStylesProvider =
    StateNotifierProvider<DetectionStylesNotifier, DetectionStyles>((ref) {
      return DetectionStylesNotifier();
    });

/// One pattern's override (null = untouched). Watch THIS from per-pattern UI
/// so sibling changes don't rebuild it.
final detectionPatternStyleProvider =
    Provider.family<DetectionPatternStyle?, String>(
      (ref, patternId) => ref.watch(detectionStylesProvider).of(patternId),
    );

/// Notifier over [DetectionStylesStore]. Best-effort hydrate/persist that
/// never throws when prefs are unavailable (widget tests without bindings) —
/// the DetectionSettingsNotifier idiom.
class DetectionStylesNotifier extends StateNotifier<DetectionStyles> {
  DetectionStylesNotifier({DetectionStylesStore? store})
    : _store = store ?? DetectionStylesStore(),
      super(DetectionStyles.empty) {
    _hydrate();
  }

  final DetectionStylesStore _store;

  Future<void> _hydrate() async {
    try {
      final stored = await _store.load();
      if (!mounted) return;
      if (stored != state) state = stored;
    } catch (_) {
      // best-effort; keep the empty (shipped-defaults) state.
    }
  }

  /// Merge [change] into [patternId]'s current override and persist. An
  /// override whose every field ends up null is REMOVED (absent = default).
  Future<void> _update(
    String patternId,
    DetectionPatternStyle Function(DetectionPatternStyle current) change,
  ) async {
    final next = change(state.of(patternId) ?? const DetectionPatternStyle());
    try {
      final updated = await _store.setPatternStyle(patternId, next);
      if (mounted) state = updated;
    } catch (_) {
      // best-effort persistence: still reflect the change in memory.
      if (!mounted) return;
      final map = Map<String, DetectionPatternStyle>.from(state.byPattern);
      if (next.isEmpty) {
        map.remove(patternId);
      } else {
        map[patternId] = next;
      }
      state = DetectionStyles(map);
    }
  }

  /// Set (or clear, with null) the `#RRGGBB` hue override for [patternId].
  Future<void> setColorHex(String patternId, String? colorHex) => _update(
    patternId,
    (c) => DetectionPatternStyle(
      colorHex: colorHex,
      inactiveIntensity: c.inactiveIntensity,
      activeIntensity: c.activeIntensity,
      verifyShortPaths: c.verifyShortPaths,
      lexicon: c.lexicon,
    ),
  );

  /// Set (or clear, with null) the DETECTED-state intensity multiplier.
  Future<void> setInactiveIntensity(String patternId, double? value) =>
      _update(
        patternId,
        (c) => DetectionPatternStyle(
          colorHex: c.colorHex,
          inactiveIntensity: value,
          activeIntensity: c.activeIntensity,
          verifyShortPaths: c.verifyShortPaths,
          lexicon: c.lexicon,
        ),
      );

  /// Set (or clear, with null) the ACTIVE-state intensity multiplier. Only
  /// meaningful where an active state exists (`detectionPatternHasActiveState`
  /// — verified paths today, #990); the lab UI gates its controls on that.
  Future<void> setActiveIntensity(String patternId, double? value) => _update(
    patternId,
    (c) => DetectionPatternStyle(
      colorHex: c.colorHex,
      inactiveIntensity: c.inactiveIntensity,
      activeIntensity: value,
      verifyShortPaths: c.verifyShortPaths,
      lexicon: c.lexicon,
    ),
  );

  /// Set (or clear, with null) the short-path verification gate (#1031 slice
  /// 2 behavior knob, paths only — null = the shipped #990 default, true).
  Future<void> setVerifyShortPaths(String patternId, bool? value) => _update(
    patternId,
    (c) => DetectionPatternStyle(
      colorHex: c.colorHex,
      inactiveIntensity: c.inactiveIntensity,
      activeIntensity: c.activeIntensity,
      verifyShortPaths: value,
      lexicon: c.lexicon,
    ),
  );

  /// Set (or clear, with null) the command lexicon override (#1031 slice 2
  /// behavior knob, command pattern only — null = `kDefaultCommandLexicon`).
  Future<void> setLexicon(String patternId, List<String>? value) => _update(
    patternId,
    (c) => DetectionPatternStyle(
      colorHex: c.colorHex,
      inactiveIntensity: c.inactiveIntensity,
      activeIntensity: c.activeIntensity,
      verifyShortPaths: c.verifyShortPaths,
      lexicon: value == null ? null : List<String>.unmodifiable(value),
    ),
  );

  /// Reset ONE pattern to shipped defaults (#1031 IA "Reset this pattern").
  Future<void> resetPattern(String patternId) =>
      _update(patternId, (_) => const DetectionPatternStyle());

  /// Clear EVERY tuned override (#1031 IA "Reset lab customizations"; the
  /// seam the extended Settings reset calls in the lab slice).
  Future<void> clearAllTuned() async {
    try {
      await _store.clearAllTuned();
    } catch (_) {
      // best-effort persistence
    }
    if (mounted) state = DetectionStyles.empty;
  }
}
