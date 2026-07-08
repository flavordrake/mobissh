// Detection exceptions — "Not a URL" / "Not a file" reports (#995).
//
// When the owner marks a detected anchor as a false positive, the EXACT matched
// text is persisted here and suppresses future detection affordances of that
// text (exact-match suppression is the safe v1; generalizing a report into a
// pattern fix is an upstream detector change informed by this corpus — the
// records ride in the feedback bundle for exactly that purpose).
//
// Storage follows the favorites_store.dart precedent: a single JSON blob in
// shared_preferences under [detectionExceptionsPrefsKey], schema version INSIDE
// the value (never a key bump), corrupt / unknown-version data falls back to an
// empty list (validate → fallback, never crash).
//
// Scope is GLOBAL by default (a false-positive string is usually falsely
// matched everywhere); each record carries [DetectionException.host] and
// [DetectionException.scope] so per-profile scoping can come later without a
// schema break.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences key. `v1` in the NAME is the storage namespace only; the
/// migratable schema version lives inside the value (see [_schemaVersion]).
const String detectionExceptionsPrefsKey = 'mobissh.detection.exceptions.v1';

/// Current in-value schema version. Bump + migrate in [DetectionExceptionsStore.load]
/// on a shape change.
const int _schemaVersion = 1;

/// Maps a concrete pattern id to its suppression FAMILY. The `url` regex
/// pattern and the `osc8` hyperlink source are ONE user-facing type (a link),
/// so a report against either suppresses the text for both. Any other pattern
/// (path, a future custom regex) is its own family.
String detectionExceptionFamily(String patternId) =>
    patternId == 'osc8' ? 'url' : patternId;

/// One persisted false-positive report. Equality/dedupe is by
/// (family([patternId]), [matchedText]) — the same text reported via `url` and
/// `osc8` is one exception.
class DetectionException {
  const DetectionException({
    required this.matchedText,
    required this.patternId,
    this.contextLine = '',
    this.tsMs = 0,
    this.host = '',
    this.scope = 'global',
  });

  /// The EXACT matched text the detector produced (the anchor payload) — the
  /// suppression key. For a file:// anchor this is the file:// URI as matched,
  /// not the derived bare path.
  final String matchedText;

  /// The concrete pattern id that produced the match (`url`/`osc8`/`path`).
  /// Diagnostic — suppression uses [family].
  final String patternId;

  /// A small snippet of the line the match appeared on (may be empty when the
  /// line was not resolvable at report time). Corpus context for turning
  /// recurring false-positive CLASSES into upstream regex fixes.
  final String contextLine;

  /// Report time, epoch milliseconds (0 = unknown).
  final int tsMs;

  /// Host the session was connected to when reported (diagnostic; scope is
  /// global in v1).
  final String host;

  /// Suppression scope. v1 always writes `global`; carried in the record so a
  /// later per-profile scoping needs no schema break.
  final String scope;

  /// The suppression family this record belongs to.
  String get family => detectionExceptionFamily(patternId);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': matchedText,
    'pattern': patternId,
    if (contextLine.isNotEmpty) 'line': contextLine,
    if (tsMs > 0) 'ts': tsMs,
    if (host.isNotEmpty) 'host': host,
    'scope': scope,
  };

  /// Parse one stored record. Returns null for anything that isn't a Map with
  /// usable `text` + `pattern` strings (a bad entry is dropped, not fatal).
  static DetectionException? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final pattern = raw['pattern'];
    if (text is! String || text.trim().isEmpty) return null;
    if (pattern is! String || pattern.isEmpty) return null;
    final line = raw['line'];
    final ts = raw['ts'];
    final host = raw['host'];
    final scope = raw['scope'];
    return DetectionException(
      matchedText: text,
      patternId: pattern,
      contextLine: line is String ? line : '',
      tsMs: ts is int ? ts : 0,
      host: host is String ? host : '',
      scope: (scope is String && scope.isNotEmpty) ? scope : 'global',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DetectionException &&
          other.family == family &&
          other.matchedText == matchedText);

  @override
  int get hashCode => Object.hash(family, matchedText);

  @override
  String toString() => 'DetectionException($patternId, $matchedText)';
}

/// Persistence layer for detection exceptions (#995). UI consumers go through
/// `detectionExceptionsProvider` (state/detection_exceptions_providers.dart).
/// Tests inject a [SharedPreferences] via [SharedPreferences.setMockInitialValues]
/// and construct directly (mirrors [FavoritesStore]).
class DetectionExceptionsStore {
  DetectionExceptionsStore({SharedPreferences? prefs}) : _prefs = prefs;

  // ignore_for_file: prefer_initializing_formals
  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read all stored exceptions, oldest first. Returns an empty list when
  /// nothing is stored, the JSON is malformed, the shape is wrong, or the
  /// schema version is unknown (corrupt-resilience per .claude/rules —
  /// validate → fallback to empty, never crash).
  Future<List<DetectionException>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(detectionExceptionsPrefsKey);
    if (raw == null || raw.isEmpty) return <DetectionException>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <DetectionException>[];
      final version = decoded['v'];
      // Unknown / future version: don't risk misreading a shape we don't know.
      if (version is! int || version != _schemaVersion) {
        return <DetectionException>[];
      }
      final entries = decoded['entries'];
      if (entries is! List) return <DetectionException>[];
      final out = <DetectionException>[];
      final seen = <DetectionException>{};
      for (final entry in entries) {
        final e = DetectionException.fromJson(entry);
        if (e == null) continue;
        if (seen.add(e)) out.add(e);
      }
      return out;
    } on FormatException {
      return <DetectionException>[];
    }
  }

  Future<void> _saveAll(List<DetectionException> entries) async {
    final prefs = await _ensure();
    final encoded = jsonEncode(<String, dynamic>{
      'v': _schemaVersion,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    await prefs.setString(detectionExceptionsPrefsKey, encoded);
  }

  /// Add [exception] (no-op when the same family+text is already stored, or
  /// when the matched text is blank). Returns the updated list.
  Future<List<DetectionException>> add(DetectionException exception) async {
    if (exception.matchedText.trim().isEmpty) return load();
    final entries = await load();
    if (entries.contains(exception)) return entries;
    entries.add(exception);
    await _saveAll(entries);
    return entries;
  }

  /// Remove the exception for ([patternId]'s family, [matchedText]).
  /// Returns the updated list.
  Future<List<DetectionException>> remove({
    required String patternId,
    required String matchedText,
  }) async {
    final target = DetectionException(
      matchedText: matchedText,
      patternId: patternId,
    );
    final entries = await load();
    final before = entries.length;
    entries.removeWhere((e) => e == target);
    if (entries.length != before) await _saveAll(entries);
    return entries;
  }

  /// Clear all exceptions.
  Future<void> clear() async {
    final prefs = await _ensure();
    await prefs.remove(detectionExceptionsPrefsKey);
  }
}
