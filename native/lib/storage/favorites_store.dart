// Per-profile path favorites for the SFTP file browser (#632).
//
// A profile's favorites are a set of starred remote absolute paths, SHARED
// across every session of that profile and PERSISTED across app restart. They
// are keyed by profile identity `host:port:username` (the same tuple
// [SavedProfile.identityKey] / [SessionEntry.profileKey] use), so two different
// profiles have independent sets while two sessions of the SAME profile see one
// shared set.
//
// Storage: a single JSON blob in shared_preferences under
// [favoritesPrefsKey]. The schema version lives INSIDE the value (not the key),
// per .claude/rules code-style — so a future migration never strands data and a
// staleness bug is never "fixed" by bumping the key. Corrupt / unknown-version
// data falls back to an empty model (validate → fallback, never crash).

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One favorited path for a profile. A favorite is a remote absolute path with
/// an optional human-friendly [label]. Equality is by [path] (normalized) — a
/// profile favorites a directory once.
class PathFavorite {
  const PathFavorite({required this.path, this.label});

  /// Remote path, normalized (no trailing slash except root `/`).
  final String path;

  /// Optional display label. When null/empty the UI shows the path itself.
  final String? label;

  /// Display text for the favorites menu — the label when present, else path.
  String get display => (label != null && label!.isNotEmpty) ? label! : path;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{'path': path};
    if (label != null && label!.isNotEmpty) out['label'] = label;
    return out;
  }

  /// Parse one stored favorite. Returns null for anything that isn't a Map with
  /// a usable `path` string (corrupt-resilience — a bad entry is dropped, not
  /// fatal to the whole load).
  static PathFavorite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pathRaw = raw['path'];
    if (pathRaw is! String) return null;
    final normalized = normalizePath(pathRaw);
    if (normalized.isEmpty) return null;
    final labelRaw = raw['label'];
    final label = (labelRaw is String && labelRaw.isNotEmpty) ? labelRaw : null;
    return PathFavorite(path: normalized, label: label);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is PathFavorite && other.path == path);

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'PathFavorite($path${label != null ? ', $label' : ''})';
}

/// Normalize a remote path for stable equality / dedupe. Trims whitespace and
/// strips a single trailing slash unless the whole path is root `/`. Leaves
/// `~`, relative, and absolute paths otherwise untouched (the SFTP layer
/// resolves them on navigation — favorites store exactly what the browser uses
/// as its listing path so quick-nav round-trips).
String normalizePath(String path) {
  var p = path.trim();
  if (p.isEmpty) return '';
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// shared_preferences key. Versioned in the NAME only as the storage namespace
/// (`v1`); the migratable schema version lives inside the value (see
/// [_schemaVersion]) so a schema change migrates in place without a key bump.
const String favoritesPrefsKey = 'mobissh.favorites.v1';

/// Current in-value schema version. Bump + migrate in [load] on a shape change.
const int _schemaVersion = 1;

/// Persistence layer for per-profile path favorites (#632). UI consumers go
/// through `favoritesStoreProvider` (state/favorites_providers.dart). Tests
/// inject a [SharedPreferences] via [SharedPreferences.setMockInitialValues]
/// and construct directly (mirrors [ProfilesStore]).
class FavoritesStore {
  FavoritesStore({SharedPreferences? prefs}) : _prefs = prefs;

  // ignore_for_file: prefer_initializing_formals
  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read the whole favorites model: `identityKey -> ordered favorites`.
  /// Returns an empty map when nothing is stored, the JSON is malformed, the
  /// shape is wrong, or the schema version is unknown (corrupt-resilience per
  /// .claude/rules — validate → fallback to empty, never crash).
  Future<Map<String, List<PathFavorite>>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(favoritesPrefsKey);
    if (raw == null || raw.isEmpty) return <String, List<PathFavorite>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<PathFavorite>>{};
      final version = decoded['version'];
      // Unknown / future version: don't risk misreading a shape we don't know.
      if (version is! int || version != _schemaVersion) {
        return <String, List<PathFavorite>>{};
      }
      final profiles = decoded['profiles'];
      if (profiles is! Map) return <String, List<PathFavorite>>{};
      final out = <String, List<PathFavorite>>{};
      profiles.forEach((key, value) {
        if (key is! String || value is! List) return;
        final favs = <PathFavorite>[];
        final seen = <String>{};
        for (final entry in value) {
          final fav = PathFavorite.fromJson(entry);
          if (fav == null) continue;
          if (seen.add(fav.path)) favs.add(fav);
        }
        if (favs.isNotEmpty) out[key] = favs;
      });
      return out;
    } on FormatException {
      return <String, List<PathFavorite>>{};
    }
  }

  /// Overwrite the entire favorites model. Empty per-profile lists are dropped
  /// so a cleared profile leaves no residue.
  Future<void> _saveAll(Map<String, List<PathFavorite>> model) async {
    final prefs = await _ensure();
    final profiles = <String, dynamic>{};
    model.forEach((key, favs) {
      if (favs.isEmpty) return;
      profiles[key] = favs.map((f) => f.toJson()).toList();
    });
    final encoded = jsonEncode({
      'version': _schemaVersion,
      'profiles': profiles,
    });
    await prefs.setString(favoritesPrefsKey, encoded);
  }

  /// Favorites for one profile identity, in insertion order. Empty when none.
  Future<List<PathFavorite>> favoritesFor(String identityKey) async {
    final model = await load();
    return model[identityKey] ?? const <PathFavorite>[];
  }

  /// True when [path] (normalized) is favorited for [identityKey].
  Future<bool> isFavorite(String identityKey, String path) async {
    final target = normalizePath(path);
    if (target.isEmpty) return false;
    final favs = await favoritesFor(identityKey);
    return favs.any((f) => f.path == target);
  }

  /// Add [path] to [identityKey]'s favorites (no-op if already present).
  /// Returns the updated list. An empty/blank path is rejected (no-op).
  Future<List<PathFavorite>> add(
    String identityKey,
    String path, {
    String? label,
  }) async {
    final normalized = normalizePath(path);
    if (normalized.isEmpty) return favoritesFor(identityKey);
    final model = await load();
    final favs = List<PathFavorite>.from(
      model[identityKey] ?? const <PathFavorite>[],
    );
    if (!favs.any((f) => f.path == normalized)) {
      favs.add(PathFavorite(path: normalized, label: label));
      model[identityKey] = favs;
      await _saveAll(model);
    }
    return model[identityKey] ?? favs;
  }

  /// Remove [path] from [identityKey]'s favorites. Returns the updated list.
  Future<List<PathFavorite>> remove(String identityKey, String path) async {
    final normalized = normalizePath(path);
    final model = await load();
    final favs = List<PathFavorite>.from(
      model[identityKey] ?? const <PathFavorite>[],
    );
    final before = favs.length;
    favs.removeWhere((f) => f.path == normalized);
    if (favs.length != before) {
      if (favs.isEmpty) {
        model.remove(identityKey);
      } else {
        model[identityKey] = favs;
      }
      await _saveAll(model);
    }
    return model[identityKey] ?? const <PathFavorite>[];
  }

  /// Toggle [path] for [identityKey]. Returns the NEW favorited state
  /// (true = now favorited). Drives the star control's filled/outline.
  Future<bool> toggle(String identityKey, String path) async {
    final normalized = normalizePath(path);
    if (normalized.isEmpty) return false;
    if (await isFavorite(identityKey, normalized)) {
      await remove(identityKey, normalized);
      return false;
    }
    await add(identityKey, normalized);
    return true;
  }

  /// Clear ALL favorites for one profile (the "Clear all favorites" action).
  Future<void> clear(String identityKey) async {
    final model = await load();
    if (model.remove(identityKey) != null) {
      await _saveAll(model);
    }
  }
}
