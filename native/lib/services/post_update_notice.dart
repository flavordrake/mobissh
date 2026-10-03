// Post-update notice (#1258, docs/self-update.md R16): "Updated to <version>"
// with a "What's new" action, once, on the first launch whose running build is
// GREATER than the stored last-run build. A fresh install (nothing stored, or a
// corrupt value) is stored silently. Versions live INSIDE the stored values
// (code-style rule: never bump a key).
//
// The notes come from the manifest of the build that was handed to the
// installer, saved at hand-off ([PostUpdateStore.savePending]) so they show
// after the relaunch with no network.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'self_update.dart';

/// `{"v":1,"build":B}` — the build that last ran.
const String lastRunPrefKey = 'mobissh.update.lastRun';

/// `{"v":1,"build":B,"version":"…","notes":"…"}` — saved at hand-off.
const String pendingPrefKey = 'mobissh.update.pending';

Map<String, dynamic>? _v1(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic> && decoded['v'] == 1) return decoded;
  } on FormatException {
    // corrupt → treated as absent
  }
  return null;
}

/// The stored last-run build, or null for missing / corrupt / unknown `v`.
int? parseLastRun(String? raw) {
  final build = _v1(raw)?['build'];
  return build is int && build > 0 ? build : null;
}

@immutable
class PostUpdateDecision {
  const PostUpdateDecision({required this.show, required this.write});
  final bool show;
  final bool write;
}

/// The decision table (R16). [running] null = no `MOBISSH_BUILD` (a
/// `flutter run` or hand-built APK): never shown, never stored.
PostUpdateDecision postUpdateNotice({required int? running, required int? stored}) {
  if (running == null) {
    return const PostUpdateDecision(show: false, write: false);
  }
  if (stored == running) {
    return const PostUpdateDecision(show: false, write: false);
  }
  return PostUpdateDecision(show: stored != null && stored < running, write: true);
}

/// What to show: [version] null when no pending notes match the running build
/// (the caller falls back to the installed version label).
@immutable
class PostUpdateNotice {
  const PostUpdateNotice({this.version, this.notes = ''});
  final String? version;
  final String notes;
}

class PostUpdateStore {
  PostUpdateStore({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance();

  final Future<SharedPreferences> _prefs;

  /// R16: saved just before the hand-off to the installer.
  Future<void> savePending(UpdateManifest manifest) async {
    final prefs = await _prefs;
    await prefs.setString(
      pendingPrefKey,
      jsonEncode(<String, Object?>{
        'v': 1,
        'build': manifest.build,
        'version': manifest.version,
        'notes': manifest.notes,
      }),
    );
  }

  /// Applies the decision table and stores the running build. Returns the
  /// notice to show, or null. Never throws.
  Future<PostUpdateNotice?> evaluate(int? running) async {
    try {
      final prefs = await _prefs;
      final d = postUpdateNotice(
        running: running,
        stored: parseLastRun(prefs.getString(lastRunPrefKey)),
      );
      if (d.write) {
        await prefs.setString(
          lastRunPrefKey,
          jsonEncode(<String, Object?>{'v': 1, 'build': running}),
        );
      }
      if (!d.show) return null;
      final pending = _v1(prefs.getString(pendingPrefKey));
      await prefs.remove(pendingPrefKey);
      if (pending == null || pending['build'] != running) {
        return const PostUpdateNotice();
      }
      final version = pending['version'];
      final notes = pending['notes'];
      return PostUpdateNotice(
        version: version is String && version.isNotEmpty ? version : null,
        notes: notes is String ? notes : '',
      );
    } catch (e) {
      debugPrint('update: post-update notice skipped ($e)');
      return null;
    }
  }
}
