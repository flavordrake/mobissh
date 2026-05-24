// Saved-profile persistence for the native client (#501).
//
// Mirrors the PWA's `getProfiles` / `saveProfile` pattern: a JSON-encoded list
// of connection metadata persisted in shared_preferences under the key
// `mobissh.profiles.v1`. Credentials are explicitly NOT stored here — the
// vault (Phase 3) owns secrets. This file owns identity only.
//
// The matching PWA export shape (see `exportProfilesJson` in
// src/modules/profiles.ts) is `{ version: 1, exportedAt, profiles: [...] }`.

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted profile shape. Connection metadata + optional visual identity.
/// No credentials. No vaultId. Equality is by (host, port, username) — the
/// natural identity used for dedupe everywhere else in the app.
class SavedProfile {
  SavedProfile({
    required this.title,
    required this.host,
    required this.port,
    required this.username,
    this.theme,
    this.color,
  });

  final String title;
  final String host;
  final int port;
  final String username;
  final String? theme;
  final String? color;

  /// Identity key for dedupe / lookup. Matches the PWA's behavior of treating
  /// (host:port:username) as the unique constraint.
  String get identityKey => '$host:$port:$username';

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'title': title,
      'host': host,
      'port': port,
      'username': username,
    };
    if (theme != null) out['theme'] = theme;
    if (color != null) out['color'] = color;
    return out;
  }

  factory SavedProfile.fromJson(Map<String, dynamic> json) {
    final hostRaw = json['host'];
    final usernameRaw = json['username'];
    if (hostRaw is! String || hostRaw.isEmpty) {
      throw const FormatException('profile missing required field: host');
    }
    if (usernameRaw is! String || usernameRaw.isEmpty) {
      throw const FormatException('profile missing required field: username');
    }

    // Port: JSON numbers parse as int OR double depending on encoder. Accept
    // either, fall back to 22.
    int port = 22;
    final portRaw = json['port'];
    if (portRaw is int) {
      port = portRaw;
    } else if (portRaw is double) {
      port = portRaw.toInt();
    } else if (portRaw is String) {
      port = int.tryParse(portRaw) ?? 22;
    }
    if (port <= 0 || port > 65535) port = 22;

    final titleRaw = json['title'];
    final title = (titleRaw is String && titleRaw.isNotEmpty)
        ? titleRaw
        : '$usernameRaw@$hostRaw';

    String? theme;
    final themeRaw = json['theme'];
    if (themeRaw is String && themeRaw.isNotEmpty) theme = themeRaw;

    String? color;
    final colorRaw = json['color'];
    if (colorRaw is String && colorRaw.isNotEmpty) color = colorRaw;

    return SavedProfile(
      title: title,
      host: hostRaw,
      port: port,
      username: usernameRaw,
      theme: theme,
      color: color,
    );
  }

  SavedProfile copyWith({String? title}) {
    return SavedProfile(
      title: title ?? this.title,
      host: host,
      port: port,
      username: username,
      theme: theme,
      color: color,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavedProfile &&
          other.host == host &&
          other.port == port &&
          other.username == username);

  @override
  int get hashCode => Object.hash(host, port, username);

  @override
  String toString() => 'SavedProfile($title, $username@$host:$port)';
}

/// Result of an import operation. Mirrors the PWA's `ImportResult` shape so
/// the UI can show parallel toast messages.
class ImportResult {
  ImportResult({this.added = 0, this.skipped = 0, this.errors = const []});
  final int added;
  final int skipped;
  final List<String> errors;
}

/// shared_preferences key. Versioned so a future schema change can migrate
/// in-place without colliding with v1 data.
const String profilesPrefsKey = 'mobissh.profiles.v1';

/// Persistence layer for saved profiles. UI consumers go through
/// `profilesStoreProvider` (state/profiles_providers.dart) so they can be
/// observed via Riverpod; tests inject a [SharedPreferences] via
/// [SharedPreferences.setMockInitialValues] and construct directly.
class ProfilesStore {
  ProfilesStore({SharedPreferences? prefs}) : _prefs = prefs;

  // Cached SharedPreferences. Lazily replaced by [_ensure] on first call when
  // the constructor wasn't given an explicit instance. Tests may pass in a
  // pre-seeded prefs handle to skip async resolution.
  SharedPreferences? _prefs;
  // ignore_for_file: prefer_initializing_formals

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read all profiles from storage. Returns [] when nothing is stored or
  /// the stored JSON is malformed (corrupt-resilience per .claude/rules).
  Future<List<SavedProfile>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(profilesPrefsKey);
    if (raw == null || raw.isEmpty) return <SavedProfile>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <SavedProfile>[];
      final out = <SavedProfile>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        try {
          out.add(SavedProfile.fromJson(Map<String, dynamic>.from(entry)));
        } on FormatException {
          // Skip corrupt entries silently — they would have been quarantined
          // at write time anyway; tolerate stragglers.
        }
      }
      return out;
    } on FormatException {
      return <SavedProfile>[];
    }
  }

  /// Overwrite the entire profile list. The native UI calls `save(list)`
  /// after each mutating operation; there's no incremental update API.
  Future<void> save(List<SavedProfile> profiles) async {
    final prefs = await _ensure();
    final encoded = jsonEncode(profiles.map((p) => p.toJson()).toList());
    await prefs.setString(profilesPrefsKey, encoded);
  }

  /// Import from a PWA-shaped export. Accepts:
  ///   `{ version: 1, exportedAt: "iso-8601", profiles: [...] }`
  /// Merges with existing storage; dedupes on (host:port:username).
  ///
  /// Returns an [ImportResult] enumerating added/skipped/errors. Does NOT
  /// throw on malformed input — that's a user-recoverable error reported via
  /// the result.
  Future<ImportResult> importFromJson(String json) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      return ImportResult(errors: ['Not valid JSON: ${e.message}']);
    }

    // Accept either:
    //   1) The PWA's native-export envelope `{ version, profiles[] }`
    //   2) The legacy bare-array shape (forward-compat with #419 exports).
    List<dynamic> entries;
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final version = decoded['version'];
      if (version != null && version != 1) {
        return ImportResult(errors: [
          'Unsupported export version: $version (this client supports v1).',
        ]);
      }
      final profilesRaw = decoded['profiles'];
      if (profilesRaw is! List) {
        return ImportResult(errors: [
          'Export envelope missing `profiles` array.',
        ]);
      }
      entries = profilesRaw;
    } else {
      return ImportResult(errors: [
        'Wrong file shape — expected an export envelope or profile array.',
      ]);
    }

    final existing = await load();
    final existingKeys = existing.map((p) => p.identityKey).toSet();
    final errors = <String>[];
    int added = 0;
    int skipped = 0;

    for (final entry in entries) {
      if (entry is! Map) {
        errors.add('Skipped a non-object entry.');
        continue;
      }
      try {
        final profile = SavedProfile.fromJson(Map<String, dynamic>.from(entry));
        if (existingKeys.contains(profile.identityKey)) {
          skipped++;
          continue;
        }
        existing.add(profile);
        existingKeys.add(profile.identityKey);
        added++;
      } on FormatException catch (e) {
        errors.add(e.message);
      }
    }

    if (added > 0) {
      await save(existing);
    }

    return ImportResult(added: added, skipped: skipped, errors: errors);
  }

  /// Delete a single profile by identity. Persists if anything was removed.
  Future<void> remove({
    required String host,
    required int port,
    required String username,
  }) async {
    final list = await load();
    final before = list.length;
    list.removeWhere(
      (p) => p.host == host && p.port == port && p.username == username,
    );
    if (list.length != before) {
      await save(list);
    }
  }
}
