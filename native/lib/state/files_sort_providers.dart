// Per-profile file-browser sort preference (#951).
//
// The SFTP explorer's sort key + direction are PER-PROFILE (keyed by the
// `host:port:username` identity, like favorites #632) and persisted across app
// restart. Two sessions of the same profile share one sort; two profiles sort
// independently. Default: name, ascending.
//
// Storage mirrors the favorites store: a single versioned JSON blob in
// shared_preferences (schema version INSIDE the value, per .claude/rules
// code-style — never a key bump). Corrupt / unknown-version data falls back to
// the default (validate → fallback, never crash).
//
// Sorting is done UI-SIDE (see [sortEntries]) right before building the list,
// so changing the sort re-renders WITHOUT an SFTP refetch. Directories are
// ALWAYS pinned first, regardless of key/direction.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/session_messages.dart';

/// What the file list is ordered by. `type` sorts by file extension/kind
/// (directories are pinned first regardless, so this orders files by suffix).
enum FilesSortKey { name, modified, size, type }

/// Immutable sort preference: the [key] and the [ascending] direction.
@immutable
class FilesSortPref {
  const FilesSortPref({this.key = FilesSortKey.name, this.ascending = true});

  final FilesSortKey key;
  final bool ascending;

  FilesSortPref copyWith({FilesSortKey? key, bool? ascending}) => FilesSortPref(
    key: key ?? this.key,
    ascending: ascending ?? this.ascending,
  );

  @override
  bool operator ==(Object other) =>
      other is FilesSortPref &&
      other.key == key &&
      other.ascending == ascending;

  @override
  int get hashCode => Object.hash(key, ascending);

  @override
  String toString() => 'FilesSortPref($key, ${ascending ? 'asc' : 'desc'})';
}

/// The default sort: name, ascending.
const FilesSortPref filesSortDefault = FilesSortPref();

/// shared_preferences key (storage namespace `v1`; migratable schema version is
/// inside the value — see [_schemaVersion]).
const String filesSortPrefKey = 'mobissh.files.sort.v1';

const int _schemaVersion = 1;

String _keyName(FilesSortKey k) => k.name;

FilesSortKey _keyFromName(Object? raw) {
  if (raw is String) {
    for (final k in FilesSortKey.values) {
      if (k.name == raw) return k;
    }
  }
  return FilesSortKey.name;
}

/// Decode the whole `profileKey -> FilesSortPref` model from a stored blob.
/// Returns empty on null/malformed/unknown-version input (corrupt-resilience).
Map<String, FilesSortPref> _decodeAll(String? raw) {
  if (raw == null || raw.isEmpty) return <String, FilesSortPref>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, FilesSortPref>{};
    final version = decoded['version'];
    if (version is! int || version != _schemaVersion) {
      return <String, FilesSortPref>{};
    }
    final profiles = decoded['profiles'];
    if (profiles is! Map) return <String, FilesSortPref>{};
    final out = <String, FilesSortPref>{};
    profiles.forEach((key, value) {
      if (key is! String || value is! Map) return;
      out[key] = FilesSortPref(
        key: _keyFromName(value['key']),
        ascending: value['ascending'] is bool ? value['ascending'] as bool : true,
      );
    });
    return out;
  } on FormatException {
    return <String, FilesSortPref>{};
  }
}

String _encodeAll(Map<String, FilesSortPref> model) {
  final profiles = <String, dynamic>{};
  model.forEach((key, pref) {
    profiles[key] = {'key': _keyName(pref.key), 'ascending': pref.ascending};
  });
  return jsonEncode({'version': _schemaVersion, 'profiles': profiles});
}

/// Per-profile sort notifier. Hydrates its profile's entry from the shared blob
/// and persists by read-modify-write so sibling profiles' prefs are preserved.
class FilesSortNotifier extends StateNotifier<FilesSortPref> {
  FilesSortNotifier(this._profileKey, {Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(filesSortDefault) {
    _hydrate();
  }

  final String _profileKey;
  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final model = _decodeAll(prefs.getString(filesSortPrefKey));
      final stored = model[_profileKey];
      if (stored != null && stored != state) state = stored;
    } catch (_) {
      // best-effort; keep default if prefs unavailable (tests).
    }
  }

  Future<void> _update(FilesSortPref next) async {
    state = next;
    try {
      final prefs = await _prefs;
      final model = _decodeAll(prefs.getString(filesSortPrefKey));
      model[_profileKey] = next;
      await prefs.setString(filesSortPrefKey, _encodeAll(model));
    } catch (_) {
      // best-effort persistence
    }
  }

  /// Set the sort key (keeps the current direction).
  Future<void> setKey(FilesSortKey key) => _update(state.copyWith(key: key));

  /// Set the direction explicitly.
  Future<void> setAscending(bool ascending) =>
      _update(state.copyWith(ascending: ascending));

  /// Flip the direction.
  Future<void> toggleDirection() =>
      _update(state.copyWith(ascending: !state.ascending));
}

/// Per-profile sort preference, keyed by `host:port:username` identity.
final filesSortProvider =
    StateNotifierProvider.family<FilesSortNotifier, FilesSortPref, String>(
      (ref, profileKey) => FilesSortNotifier(profileKey),
    );

int _byName(SftpEntry a, SftpEntry b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());

/// File extension (kind), lowercased, for the `type` sort. Empty when none.
String _extension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Pure comparator: directories ALWAYS first (regardless of [key]/[ascending]),
/// then by the chosen key with [ascending] direction. Name is the stable
/// tiebreak for every key so equal mtimes/sizes/types keep a deterministic
/// order.
int compareEntries(
  SftpEntry a,
  SftpEntry b, {
  required FilesSortKey key,
  required bool ascending,
}) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  final dir = ascending ? 1 : -1;
  int c;
  switch (key) {
    case FilesSortKey.name:
      c = _byName(a, b);
    case FilesSortKey.modified:
      c = (a.modifyTime ?? 0).compareTo(b.modifyTime ?? 0);
      if (c == 0) c = _byName(a, b);
    case FilesSortKey.size:
      c = (a.size ?? 0).compareTo(b.size ?? 0);
      if (c == 0) c = _byName(a, b);
    case FilesSortKey.type:
      c = _extension(a.name).compareTo(_extension(b.name));
      if (c == 0) c = _byName(a, b);
  }
  return dir * c;
}

/// Return a NEW list of [entries] sorted per [pref] (dirs always first).
List<SftpEntry> sortEntries(List<SftpEntry> entries, FilesSortPref pref) {
  final sorted = List<SftpEntry>.from(entries);
  sorted.sort(
    (a, b) => compareEntries(a, b, key: pref.key, ascending: pref.ascending),
  );
  return sorted;
}
