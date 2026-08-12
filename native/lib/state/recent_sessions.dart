// Recent-sessions persistence (#796) — native parity with the PWA's
// "Recent Sessions" quick-connect group (`src/modules/profiles.ts`, #385).
//
// The PWA persists a `recentSessions` localStorage array: each entry is a
// profile identity (host, port, username) plus a `profileIdx` used to look the
// profile back up for its title/color. Native profiles are identity-keyed and
// reorderable, so instead of an index we persist the identity fields + a
// snapshot `title` directly — the row stays correct even if the profile list is
// reordered or the source profile is deleted. The UX is identical: a one-tap
// quick-connect group, newest-first, deduped on host+port+username, capped at 5.
//
// Storage is GLOBAL (app-wide, like the saved-profile list), NOT per-session.
//
// Rules mirrored from the PWA (`src/modules/__tests__/recent-sessions.test.ts`):
//   - add() dedups on host+port+username (replaces, does not duplicate)
//   - newest entry is first
//   - the list is capped at [maxRecentSessions] (5)
//   - remove() deletes by host+port+username (used on session close)
//   - load() tolerates corrupt JSON (returns []) per config-system resilience

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences key. Matches the PWA localStorage key name so the concept
/// is recognizable across the two clients (the value shape differs — see file
/// header — but the key is the same).
const String recentSessionsPrefsKey = 'recentSessions';

/// Cap, mirroring the PWA `MAX_RECENT` constant in `src/modules/profiles.ts`.
const int maxRecentSessions = 5;

/// One recent quick-connect entry. Identity (host:port:username) is the unique
/// constraint used for dedupe/removal — the same key the rest of the app uses.
class RecentSessionEntry {
  RecentSessionEntry({
    required this.title,
    required this.host,
    required this.port,
    required this.username,
  });

  /// Snapshot of the profile's display title at connect time. Falls back to
  /// `username@host:port` when empty (handled at render time).
  final String title;
  final String host;
  final int port;
  final String username;

  /// Identity key — `host:port:username`, the app-wide dedupe constraint.
  String get identityKey => '$host:$port:$username';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'host': host,
        'port': port,
        'username': username,
      };

  /// Parse one entry. Throws [FormatException] when host/username are missing
  /// so [RecentSessionsStore.load] can skip the bad straggler (resilience).
  factory RecentSessionEntry.fromJson(Map<String, dynamic> json) {
    final hostRaw = json['host'];
    final usernameRaw = json['username'];
    if (hostRaw is! String || hostRaw.isEmpty) {
      throw const FormatException('recent session missing required field: host');
    }
    if (usernameRaw is! String || usernameRaw.isEmpty) {
      throw const FormatException(
        'recent session missing required field: username',
      );
    }

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

    return RecentSessionEntry(
      title: title,
      host: hostRaw,
      port: port,
      username: usernameRaw,
    );
  }
}

/// Persistence layer for the recent-sessions list. UI consumers go through
/// [recentSessionsStoreProvider] / [recentSessionsProvider]; tests construct
/// directly after [SharedPreferences.setMockInitialValues].
class RecentSessionsStore {
  // ignore: prefer_initializing_formals
  RecentSessionsStore({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read the recent list, newest-first. Returns [] when absent or corrupt.
  Future<List<RecentSessionEntry>> load() async {
    final prefs = await _ensure();
    final raw = prefs.getString(recentSessionsPrefsKey);
    if (raw == null || raw.isEmpty) return <RecentSessionEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <RecentSessionEntry>[];
      final out = <RecentSessionEntry>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        try {
          out.add(RecentSessionEntry.fromJson(Map<String, dynamic>.from(entry)));
        } on FormatException {
          // Skip corrupt stragglers — keep the valid ones.
        }
      }
      return out;
    } on FormatException {
      return <RecentSessionEntry>[];
    }
  }

  /// Save [entry] as the most-recent: remove any prior entry with the same
  /// host+port+username, unshift the new one to the front, cap at
  /// [maxRecentSessions]. Mirrors the PWA `saveRecentSession`.
  Future<void> add(RecentSessionEntry entry) async {
    final list = await load();
    list.removeWhere((e) => e.identityKey == entry.identityKey);
    list.insert(0, entry);
    final capped = list.length > maxRecentSessions
        ? list.sublist(0, maxRecentSessions)
        : list;
    await _write(capped);
  }

  /// Remove the entry matching host+port+username. No-op when nothing matches.
  /// Called on session close to mirror the PWA (#385, `state.ts`).
  Future<void> remove({
    required String host,
    required int port,
    required String username,
  }) async {
    final list = await load();
    final before = list.length;
    list.removeWhere(
      (e) => e.host == host && e.port == port && e.username == username,
    );
    if (list.length != before) {
      await _write(list);
    }
  }

  /// Drop every recent entry. Removes the key outright rather than writing an
  /// empty list, so [load] takes its absent-key path (same result, no stale
  /// blob left behind).
  Future<void> clear() async {
    final prefs = await _ensure();
    await prefs.remove(recentSessionsPrefsKey);
  }

  Future<void> _write(List<RecentSessionEntry> list) async {
    final prefs = await _ensure();
    final encoded = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(recentSessionsPrefsKey, encoded);
  }
}

/// Singleton [RecentSessionsStore]. Override in tests via
/// `recentSessionsStoreProvider.overrideWithValue(myStore)`.
final recentSessionsStoreProvider = Provider<RecentSessionsStore>((ref) {
  return RecentSessionsStore();
});

/// Async-loaded recent-sessions list. The connect/profile screen watches this;
/// invalidate it after add/remove so the watcher re-fetches.
final recentSessionsProvider =
    FutureProvider<List<RecentSessionEntry>>((ref) async {
  final store = ref.watch(recentSessionsStoreProvider);
  return store.load();
});
