// The single "Show experimental settings" flag (#1257).
//
// One switch, not per-feature flags: only two items qualify today (Force
// upload, Connection audit), so a per-feature map would be speculative. The
// value is versioned JSON in ONE key; the version lives inside the value
// (code-style rule), so a later per-feature map migrates without a key bump.
// Corrupt or unknown-version data falls back to the default.
//
// Hiding is display-only: both items are actions, not stored settings.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String featureFlagsPrefKey = 'mobissh.ui.featureFlags';

const int featureFlagsSchemaVersion = 1;

class FeatureFlags {
  const FeatureFlags({this.showExperimental = false});

  final bool showExperimental;

  String toJsonString() => jsonEncode(<String, Object>{
    'v': featureFlagsSchemaVersion,
    'showExperimental': showExperimental,
  });

  /// Any missing, corrupt, wrong-typed or unknown-version value → defaults.
  static FeatureFlags fromJsonString(String? raw) {
    if (raw == null) return const FeatureFlags();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != featureFlagsSchemaVersion) {
        return const FeatureFlags();
      }
      final show = decoded['showExperimental'];
      return FeatureFlags(showExperimental: show is bool && show);
    } catch (_) {
      return const FeatureFlags();
    }
  }
}

class FeatureFlagsNotifier extends StateNotifier<FeatureFlags> {
  FeatureFlagsNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(const FeatureFlags()) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      // getString throws on a non-string value; the catch keeps the default.
      state = FeatureFlags.fromJsonString(prefs.getString(featureFlagsPrefKey));
    } catch (_) {
      // best-effort; keep the default if prefs are unavailable or corrupt
    }
  }

  Future<void> setShowExperimental(bool value) =>
      _set(FeatureFlags(showExperimental: value));

  Future<void> reset() => _set(const FeatureFlags());

  Future<void> _set(FeatureFlags value) async {
    state = value;
    try {
      final prefs = await _prefs;
      await prefs.setString(featureFlagsPrefKey, value.toJsonString());
    } catch (_) {
      // best-effort persistence
    }
  }
}

final featureFlagsProvider =
    StateNotifierProvider<FeatureFlagsNotifier, FeatureFlags>(
      (ref) => FeatureFlagsNotifier(),
    );
