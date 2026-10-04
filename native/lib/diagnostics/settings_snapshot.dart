// Settings snapshot for bug reports (#1257).
//
// Bug reports carried no settings, so the "hide what we haven't used" calls in
// #1257 rested on git history alone. This adds the non-secret UI prefs and
// feature flags to the report so the next cleanup has usage data.
//
// It is an ALLOWLIST of SharedPreferences keys, never a denylist: profiles,
// hosts, usernames, key metadata and anything secret live in the same store (or
// in secure storage) and must never ride along by accident. A new setting is
// absent from reports until someone names it here.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/battery_optimization.dart' show batteryOptAskedPrefKey;
import '../state/detection_providers.dart' show detectionSettingsPrefKey;
import '../state/feature_flags_providers.dart' show featureFlagsPrefKey;
import '../state/keepalive_providers.dart' show keepaliveEnabledPrefKey;
import '../state/terminal_backend.dart' show terminalBackendPrefKey;
import '../state/tmux_control_mode_setting.dart' show tmuxControlModePrefKey;
import '../state/ui_prefs_providers.dart'
    show
        composeBarVisiblePrefKey,
        fontFamilyPrefKey,
        fontSizePrefKey,
        terminalThemePrefKey;

const List<String> kSettingsSnapshotKeys = <String>[
  fontSizePrefKey,
  fontFamilyPrefKey,
  terminalThemePrefKey,
  composeBarVisiblePrefKey,
  terminalBackendPrefKey,
  keepaliveEnabledPrefKey,
  batteryOptAskedPrefKey,
  tmuxControlModePrefKey,
  detectionSettingsPrefKey,
  featureFlagsPrefKey,
  // NOT filesSortPrefKey: its value is keyed per profile by
  // `host:port:username`, so it leaked identities into reports (0.1.13
  // security review). Allowlist by VALUE content, not just the key name.
];

/// Picks the allowlisted keys out of [stored]. A string value that decodes to
/// a JSON object (the versioned settings blobs) is included decoded; anything
/// else is included as stored.
Map<String, Object?> buildSettingsSnapshot(Map<String, Object?> stored) {
  final out = <String, Object?>{};
  for (final key in kSettingsSnapshotKeys) {
    if (!stored.containsKey(key)) continue;
    final value = stored[key];
    if (value is String && value.startsWith('{')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          out[key] = decoded;
          continue;
        }
      } catch (_) {
        // Corrupt blob: report the raw string; that is itself useful data.
      }
    }
    out[key] = value;
  }
  return out;
}

/// Reads the allowlisted prefs. Best-effort: an empty map when prefs are
/// unavailable, so a report is never blocked by its settings section.
Future<Map<String, Object?>> settingsSnapshot({
  Future<SharedPreferences>? prefs,
}) async {
  try {
    final p = await (prefs ?? SharedPreferences.getInstance());
    return buildSettingsSnapshot(<String, Object?>{
      for (final key in kSettingsSnapshotKeys)
        if (p.containsKey(key)) key: p.get(key),
    });
  } catch (_) {
    return const <String, Object?>{};
  }
}
