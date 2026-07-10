// Detection style overrides — per-pattern color/intensity tuning (#1031
// slice 1: the store + resolver the Detection Lab and the runtime affordances
// BOTH read; the lab UI comes in a later slice).
//
// One override record per pattern id: {colorHex?, inactiveIntensity?,
// activeIntensity?}. Every field is OPTIONAL and defaults to ABSENT — an empty
// store means the runtime keeps today's derived values exactly (the session
// accent + the #1000 luminance-tuned wash alphas). Composition into effective
// colors lives in `ui/detection_style_resolver.dart`, the single source of
// truth both the painters and the future lab preview consult.
//
// Keys are PLAIN STRINGS: nothing here assumes the built-in id set, so a
// later slice's `custom.<slug>` patterns store styles with zero schema change.
//
// Storage follows the favorites_store / detection_exceptions_store precedent:
// a single JSON blob in shared_preferences under [detectionStylesPrefsKey],
// schema version INSIDE the value (never a key bump), corrupt / unknown-
// version data falls back to empty (validate → fallback, never crash).
//
// Reset seams (#1031 IA review): [DetectionStylesStore.resetPattern] (the
// per-pattern "Reset this pattern") and [DetectionStylesStore.clearAllTuned]
// (the lab-wide reset the extended Settings "Reset settings" will call —
// implemented now, WIRED in the lab slice). Styles are TUNED data, not
// authored data, so they reset; authored data (custom pattern definitions,
// exception reports) lives elsewhere and survives.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences key. `v1` in the NAME is the storage namespace only; the
/// migratable schema version lives inside the value (see [_schemaVersion]).
const String detectionStylesPrefsKey = 'mobissh.detection.styles.v1';

/// Current in-value schema version. Bump + migrate in
/// [DetectionStylesStore.load] on a shape change.
const int _schemaVersion = 1;

/// One pattern's stored style override. Absent field = shipped default.
///
/// [colorHex] is a `#RRGGBB` hue replacing the session accent for BOTH the
/// bubble wash and the gutter chip (alpha is never stored — the wash alpha is
/// derived, the chip is forced opaque). [inactiveIntensity]/[activeIntensity]
/// are per-STATE multipliers on the #1000 luminance-tuned base wash alphas
/// (1.0 = shipped value); the resolver clamps them to the legibility band.
/// activeIntensity is only MEANINGFUL for patterns with a real active state
/// (verified paths, #990 — see `detectionPatternHasActiveState`); it is
/// stored uniformly so the schema needn't change when pressed-state ships.
class DetectionPatternStyle {
  const DetectionPatternStyle({
    this.colorHex,
    this.inactiveIntensity,
    this.activeIntensity,
    this.verifyShortPaths,
    this.lexicon,
  });

  /// `#RRGGBB` hue override, or null to follow the session accent.
  final String? colorHex;

  /// Multiplier on the DETECTED (inactive) wash alpha, or null for 1.0.
  final double? inactiveIntensity;

  /// Multiplier on the ACTIVE (verified) wash alpha, or null for 1.0.
  final double? activeIntensity;

  /// #1031 slice 2 BEHAVIOR knob (paths only): gate low-confidence
  /// single-segment path matches behind SFTP verification (#990). Null =
  /// shipped default (true). Stored per pattern id like every other TUNED
  /// value — the IA's documented growth path (knobs inside the styles record,
  /// so resets come free).
  final bool? verifyShortPaths;

  /// #1031 slice 2 BEHAVIOR knob (command pattern only): the app-supplied
  /// command lexicon fed to `TextPattern.command(lexicon:)`. Null = shipped
  /// default (`kDefaultCommandLexicon`).
  final List<String>? lexicon;

  /// True when every field is absent — no override at all (such a style is
  /// never persisted; setting it removes the entry).
  bool get isEmpty =>
      colorHex == null &&
      inactiveIntensity == null &&
      activeIntensity == null &&
      verifyShortPaths == null &&
      lexicon == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (colorHex != null) 'color': colorHex,
    if (inactiveIntensity != null) 'inactive': inactiveIntensity,
    if (activeIntensity != null) 'active': activeIntensity,
    if (verifyShortPaths != null) 'verify': verifyShortPaths,
    if (lexicon != null) 'lexicon': lexicon,
  };

  /// Parse one stored record, field-by-field: a wrong-typed field is dropped
  /// (falls back to absent), a non-map or all-invalid record returns null so
  /// the caller drops the entry entirely. A lexicon with any non-string entry
  /// is dropped whole (a partial lexicon would silently change detection).
  /// Never throws.
  static DetectionPatternStyle? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final color = raw['color'];
    final inactive = raw['inactive'];
    final active = raw['active'];
    final verify = raw['verify'];
    final lexiconRaw = raw['lexicon'];
    List<String>? lexicon;
    if (lexiconRaw is List && lexiconRaw.every((e) => e is String)) {
      lexicon = List<String>.unmodifiable(lexiconRaw.cast<String>());
    }
    final style = DetectionPatternStyle(
      colorHex: color is String && color.isNotEmpty ? color : null,
      inactiveIntensity: inactive is num ? inactive.toDouble() : null,
      activeIntensity: active is num ? active.toDouble() : null,
      verifyShortPaths: verify is bool ? verify : null,
      lexicon: lexicon,
    );
    return style.isEmpty ? null : style;
  }

  static bool _lexiconEquals(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is DetectionPatternStyle &&
      other.colorHex == colorHex &&
      other.inactiveIntensity == inactiveIntensity &&
      other.activeIntensity == activeIntensity &&
      other.verifyShortPaths == verifyShortPaths &&
      _lexiconEquals(other.lexicon, lexicon);

  @override
  int get hashCode => Object.hash(
    colorHex,
    inactiveIntensity,
    activeIntensity,
    verifyShortPaths,
    lexicon == null ? null : Object.hashAll(lexicon!),
  );

  @override
  String toString() =>
      'DetectionPatternStyle(color:$colorHex, inactive:$inactiveIntensity, '
      'active:$activeIntensity, verify:$verifyShortPaths, lexicon:$lexicon)';
}

/// The immutable set of stored overrides, keyed by pattern id. This is the
/// provider state the resolver composes over; [empty] (no overrides) MUST
/// reproduce today's shipped visuals exactly.
class DetectionStyles {
  const DetectionStyles(this.byPattern);

  /// No overrides — the runtime renders exactly today's derived values.
  static const DetectionStyles empty = DetectionStyles(
    <String, DetectionPatternStyle>{},
  );

  final Map<String, DetectionPatternStyle> byPattern;

  /// The override for [patternId], or null when the pattern is untouched.
  DetectionPatternStyle? of(String patternId) => byPattern[patternId];

  bool get isEmpty => byPattern.isEmpty;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DetectionStyles) return false;
    if (other.byPattern.length != byPattern.length) return false;
    for (final entry in byPattern.entries) {
      if (other.byPattern[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered([
    for (final e in byPattern.entries) Object.hash(e.key, e.value),
  ]);

  @override
  String toString() => 'DetectionStyles($byPattern)';
}

/// Persistence layer for detection style overrides (#1031). UI consumers go
/// through `detectionStylesProvider` (state/detection_style_providers.dart).
/// Tests inject a [SharedPreferences] via
/// [SharedPreferences.setMockInitialValues] and construct directly (mirrors
/// [DetectionExceptionsStore]).
class DetectionStylesStore {
  DetectionStylesStore({SharedPreferences? prefs}) : _prefs = prefs;

  // ignore_for_file: prefer_initializing_formals
  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read all stored overrides. Returns [DetectionStyles.empty] when nothing
  /// is stored, the JSON is malformed, the shape is wrong, or the schema
  /// version is unknown (corrupt-resilience per .claude/rules — validate →
  /// fallback to empty, never crash). Malformed per-pattern entries are
  /// dropped individually; good ones survive.
  Future<DetectionStyles> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(detectionStylesPrefsKey);
    if (raw == null || raw.isEmpty) return DetectionStyles.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return DetectionStyles.empty;
      final version = decoded['v'];
      // Unknown / future version: don't risk misreading a shape we don't know.
      if (version is! int || version != _schemaVersion) {
        return DetectionStyles.empty;
      }
      final styles = decoded['styles'];
      if (styles is! Map) return DetectionStyles.empty;
      final out = <String, DetectionPatternStyle>{};
      for (final entry in styles.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final style = DetectionPatternStyle.fromJson(entry.value);
        if (style == null) continue;
        out[key] = style;
      }
      return out.isEmpty ? DetectionStyles.empty : DetectionStyles(out);
    } on FormatException {
      return DetectionStyles.empty;
    }
  }

  Future<void> _saveAll(DetectionStyles styles) async {
    final prefs = await _ensure();
    if (styles.isEmpty) {
      // No overrides at all → remove the key (absent = default everywhere).
      await prefs.remove(detectionStylesPrefsKey);
      return;
    }
    final encoded = jsonEncode(<String, dynamic>{
      'v': _schemaVersion,
      'styles': {
        for (final e in styles.byPattern.entries) e.key: e.value.toJson(),
      },
    });
    await prefs.setString(detectionStylesPrefsKey, encoded);
  }

  /// Store [style] for [patternId]. An EMPTY style removes the entry (absent
  /// = shipped default). Returns the updated set.
  Future<DetectionStyles> setPatternStyle(
    String patternId,
    DetectionPatternStyle style,
  ) async {
    final current = await load();
    final next = Map<String, DetectionPatternStyle>.from(current.byPattern);
    if (style.isEmpty) {
      next.remove(patternId);
    } else {
      next[patternId] = style;
    }
    final updated = DetectionStyles(next);
    await _saveAll(updated);
    return updated;
  }

  /// Per-pattern reset (#1031 IA: "Reset this pattern") — drops [patternId]'s
  /// override, leaving every other pattern untouched. Returns the updated set.
  Future<DetectionStyles> resetPattern(String patternId) =>
      setPatternStyle(patternId, const DetectionPatternStyle());

  /// Lab-wide reset (#1031 IA: "Reset lab customizations", and the seam the
  /// extended Settings "Reset settings" calls in the lab slice): clears every
  /// TUNED override. Authored data (custom pattern definitions, exception
  /// reports) is stored elsewhere and deliberately untouched.
  Future<void> clearAllTuned() async {
    final prefs = await _ensure();
    await prefs.remove(detectionStylesPrefsKey);
  }
}
