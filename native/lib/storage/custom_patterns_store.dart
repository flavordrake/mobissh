// User-defined detection patterns (#1031 slice 3) — the AUTHORED records
// behind the lab's MY PATTERNS zone.
//
// One record per pattern: {id, name, regex source, enabled, createdTs,
// sampleLine}. The id is minted ONCE at creation ([mintCustomPatternId]) and
// NEVER re-derived from the name (#1031 IA review change 5): the style store,
// the enable bit, and the #995 exception family are all keyed by id, so a
// rename re-deriving it would silently orphan all three. Name is display-only.
//
// The regex is stored as SOURCE text and compiled DEFENSIVELY at every use
// ([compileCustomPatternRegex] never throws): the editor validates live, the
// registration path skips a non-compiling pattern, and the card renders a
// visible error state — never a crash, never a wedged scanner.
//
// Storage follows the detection_styles_store precedent: one JSON blob in
// shared_preferences under [customPatternsPrefsKey], schema version INSIDE
// the value (never a key bump), corrupt / unknown-version data falls back to
// empty, malformed entries dropped individually.
//
// These are AUTHORED data (like favorites and exception reports): they
// survive "Reset lab customizations" and Settings "Reset settings"; only an
// explicit per-pattern delete removes one.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences key. `v1` in the NAME is the storage namespace only;
/// the migratable schema version lives inside the value.
const String customPatternsPrefsKey = 'mobissh.detection.custom_patterns.v1';

/// Current in-value schema version.
const int _schemaVersion = 1;

/// The id namespace for user-defined patterns — can never collide with the
/// built-in `url` / `osc8` / `path` / `command` ids or future built-ins.
const String kCustomPatternIdPrefix = 'custom.';

/// Whether [patternId] names a user-defined pattern.
bool isCustomPatternId(String patternId) =>
    patternId.startsWith(kCustomPatternIdPrefix);

/// Mint a NEW custom-pattern id, unique against [existingIds]. Called exactly
/// once, at creation (#1031 IA review change 5) — the id is immutable
/// thereafter and is never derived from the (renameable) display name.
/// Timestamp-based with a collision suffix so ids stay unique even for two
/// creations in the same millisecond.
String mintCustomPatternId(Iterable<String> existingIds, {int? nowMs}) {
  final taken = existingIds.toSet();
  final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final base = '${kCustomPatternIdPrefix}p$ts';
  if (!taken.contains(base)) return base;
  var n = 2;
  while (taken.contains('$base-$n')) {
    n++;
  }
  return '$base-$n';
}

/// Compile a stored regex source, or null when it is empty / invalid. NEVER
/// throws — this is the single defensive compile every consumer (editor
/// validation, card error state, pattern registration) goes through.
RegExp? compileCustomPatternRegex(String source) {
  if (source.trim().isEmpty) return null;
  try {
    return RegExp(source);
  } catch (_) {
    return null;
  }
}

/// The human-readable compile error for [source], or null when it compiles
/// (or is still empty — emptiness is "incomplete", not an error). Rendered
/// inline under the editor's regex field.
String? customPatternRegexError(String source) {
  if (source.trim().isEmpty) return null;
  try {
    RegExp(source);
    return null;
  } on FormatException catch (e) {
    // FormatException.message carries the useful part ("Unterminated group"
    // etc.) without the full source dump.
    final msg = e.message.trim();
    return msg.isEmpty ? 'Invalid regular expression' : msg;
  } catch (_) {
    return 'Invalid regular expression';
  }
}

/// One user-defined pattern record. Immutable; edits go through [copyWith]
/// (which cannot change [id] or [createdTs] — minted/marked once).
class CustomPattern {
  const CustomPattern({
    required this.id,
    required this.name,
    required this.source,
    required this.enabled,
    required this.createdTs,
    this.sampleLine = '',
  });

  /// Immutable identity (see [mintCustomPatternId]) — the key into the style
  /// store, the exception family, and the registered TextPattern id.
  final String id;

  /// Display-only name; renaming never touches [id] (review change 5).
  final String name;

  /// The regex SOURCE text (compiled defensively at use).
  final String source;

  /// Whether this pattern registers on the terminal (master switch still
  /// gates it globally). Auto-cleared when the stored source stops compiling.
  final bool enabled;

  /// Creation time, epoch ms.
  final int createdTs;

  /// The sample line the editor validated against — kept so the lab card's
  /// mini preview renders the author's own example.
  final String sampleLine;

  CustomPattern copyWith({
    String? name,
    String? source,
    bool? enabled,
    String? sampleLine,
  }) {
    return CustomPattern(
      id: id,
      name: name ?? this.name,
      source: source ?? this.source,
      enabled: enabled ?? this.enabled,
      createdTs: createdTs,
      sampleLine: sampleLine ?? this.sampleLine,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'source': source,
    'enabled': enabled,
    'ts': createdTs,
    if (sampleLine.isNotEmpty) 'sample': sampleLine,
  };

  /// Parse one stored record; null for anything without a usable custom id +
  /// source (a bad entry is dropped, not fatal). An INVALID regex source
  /// still loads — the UI owns showing its error state.
  static CustomPattern? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final source = raw['source'];
    if (id is! String || !isCustomPatternId(id)) return null;
    if (source is! String || source.trim().isEmpty) return null;
    final name = raw['name'];
    final enabled = raw['enabled'];
    final ts = raw['ts'];
    final sample = raw['sample'];
    return CustomPattern(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : id,
      source: source,
      enabled: enabled is bool ? enabled : true,
      createdTs: ts is int ? ts : 0,
      sampleLine: sample is String ? sample : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomPattern &&
      other.id == id &&
      other.name == name &&
      other.source == source &&
      other.enabled == enabled &&
      other.createdTs == createdTs &&
      other.sampleLine == sampleLine;

  @override
  int get hashCode =>
      Object.hash(id, name, source, enabled, createdTs, sampleLine);

  @override
  String toString() =>
      'CustomPattern($id, "$name", /$source/, enabled:$enabled)';
}

/// Persistence layer for user-defined patterns (#1031 slice 3). UI consumers
/// go through `customPatternsProvider`. Tests inject a [SharedPreferences]
/// via [SharedPreferences.setMockInitialValues] and construct directly.
class CustomPatternsStore {
  CustomPatternsStore({SharedPreferences? prefs}) : _prefs = prefs;

  // ignore_for_file: prefer_initializing_formals
  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read all stored patterns, creation order. Empty on nothing stored /
  /// malformed JSON / wrong shape / unknown schema version; malformed entries
  /// dropped individually (validate → fallback, never crash).
  Future<List<CustomPattern>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(customPatternsPrefsKey);
    if (raw == null || raw.isEmpty) return <CustomPattern>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <CustomPattern>[];
      final version = decoded['v'];
      if (version is! int || version != _schemaVersion) {
        return <CustomPattern>[];
      }
      final patterns = decoded['patterns'];
      if (patterns is! List) return <CustomPattern>[];
      final out = <CustomPattern>[];
      final seen = <String>{};
      for (final entry in patterns) {
        final p = CustomPattern.fromJson(entry);
        if (p == null) continue;
        if (seen.add(p.id)) out.add(p);
      }
      return out;
    } on FormatException {
      return <CustomPattern>[];
    }
  }

  Future<void> saveAll(List<CustomPattern> patterns) async {
    final prefs = await _ensure();
    if (patterns.isEmpty) {
      await prefs.remove(customPatternsPrefsKey);
      return;
    }
    final encoded = jsonEncode(<String, dynamic>{
      'v': _schemaVersion,
      'patterns': patterns.map((p) => p.toJson()).toList(),
    });
    await prefs.setString(customPatternsPrefsKey, encoded);
  }

  /// Create a new pattern: mint the id (ONCE — review change 5), persist,
  /// return the created record. Enabled by default.
  Future<CustomPattern> add({
    required String name,
    required String source,
    String sampleLine = '',
    int? nowMs,
  }) async {
    final patterns = await load();
    final created = CustomPattern(
      id: mintCustomPatternId(patterns.map((p) => p.id), nowMs: nowMs),
      name: name,
      source: source,
      enabled: true,
      createdTs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      sampleLine: sampleLine,
    );
    await saveAll([...patterns, created]);
    return created;
  }

  /// Edit [id]'s definition IN PLACE — the id and createdTs never change.
  /// Returns the updated record, or null when [id] is unknown.
  Future<CustomPattern?> update(
    String id, {
    String? name,
    String? source,
    String? sampleLine,
  }) async {
    final patterns = await load();
    CustomPattern? updated;
    final next = [
      for (final p in patterns)
        if (p.id == id)
          updated = p.copyWith(name: name, source: source, sampleLine: sampleLine)
        else
          p,
    ];
    if (updated == null) return null;
    await saveAll(next);
    return updated;
  }

  /// Flip [id]'s enable bit. No-op for an unknown id.
  Future<void> setEnabled(String id, bool enabled) async {
    final patterns = await load();
    await saveAll([
      for (final p in patterns)
        if (p.id == id) p.copyWith(enabled: enabled) else p,
    ]);
  }

  /// Delete [id]'s record. (The caller owns the disclosed side effects:
  /// pruning the #995 exception family and dropping the style entry.)
  Future<void> remove(String id) async {
    final patterns = await load();
    await saveAll([
      for (final p in patterns)
        if (p.id != id) p,
    ]);
  }
}
