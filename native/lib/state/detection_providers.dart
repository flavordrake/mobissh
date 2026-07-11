// In-terminal structured-text DETECTION settings (#888 Part A).
//
// Controls whether (and what kind of) structured-text detection runs over the
// terminal's own cells. Detection is a GHOSTTY-backend affordance: the flterm
// controller registers `TextPattern`s (osc8 + url + path + command, #998) and
// maintains anchors
// across scroll / wrap / eviction (#767, #778). When a type is OFF, that pattern
// is simply NOT registered — the scan/decoration machinery already no-ops on an
// empty pattern set, so OFF means zero scan + zero decoration.
//
// Scope is GLOBAL (a viewer-affordance preference, user-uniform — per
// feedback_feature_scoping; it is NOT host/session/profile-specific). The
// persisted value is a single SCHEMA-VERSIONED JSON string (NOT a bumped key —
// code-style rule): the version lives INSIDE the value so the shape can grow
// (e.g. a per-profile override, commit-hash / issue-ref types) without a key
// bump. Hydrate is field-by-field with a per-field default fallback so a
// missing / wrong-version / corrupt value never crashes and never silently
// disables detection.
//
// Defaults are ALL TRUE (master + url + path) so the setting is purely additive:
// shipping it changes nothing for an existing user (no regression).
//
// Mirrors the `terminal_backend.dart` / `ComposeBarVisibleNotifier` notifier
// idiom: synchronous default in `super()` so the first build is stable, an
// injectable `Future<SharedPreferences>?` for tests, and best-effort
// hydrate/persist that never throws when prefs are unavailable (widget tests
// without bindings).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the versioned JSON detection settings.
/// One value, NOT a bumped key — the schema version lives inside the JSON.
const String detectionSettingsPrefKey = 'mobissh.detection.settings';

/// Current persisted-value schema version. Bump only the in-value `v` when the
/// JSON shape changes; never the key.
const int detectionSettingsSchemaVersion = 1;

/// Immutable detection settings.
///
/// [enabled] is the master switch. [url] gates BOTH the OSC-8 hyperlink source
/// and the regex URL pattern (they are one user-facing type). [path] gates the
/// absolute-file-path pattern. All default TRUE = no regression.
/// #971 kill switch for in-terminal URL/path detection — NOW OFF (detection
/// re-enabled).
///
/// History: detection was blamed for a tmux-window-switch "no repaint" and
/// force-disabled (2026-07-03) while we chased a paint root. The real root
/// turned out NOT to be paint: under mouse mode a firm status-bar tap dwelt past
/// the long-press deadline and resolved as a text SELECTION, so no SGR mouse
/// click reached tmux (device telemetry: `sentSgrTraceEventCount: 0`, paint
/// `rebuilt=32`) — the window never switched. Fixed in #974 (a status-row
/// long-press now clicks through). With that fixed, detection is back on.
///
/// The flag is kept as an emergency kill switch: set `true` to force
/// [DetectionSettings.detectUrls]/[detectPaths] to false (no pattern registered
/// → zero scan/decoration), preserving the user's stored prefs.
const bool kDetectionDisabled971 = false;

class DetectionSettings {
  const DetectionSettings({
    this.schemaVersion = detectionSettingsSchemaVersion,
    this.enabled = true,
    this.url = true,
    this.path = true,
    this.command = true,
    this.relpath = true,
  });

  /// The schema version this instance was built from (defaults to current).
  final int schemaVersion;

  /// Master switch — when false, NO detection patterns are registered.
  final bool enabled;

  /// Detect URLs (covers both OSC-8 hyperlinks and plain-text URLs).
  final bool url;

  /// Detect absolute file paths.
  final bool path;

  /// Detect prompt-anchored COMMAND LINES (#998 slice C). Default TRUE like the
  /// others (purely additive; a pre-#998 stored value hydrates it back on via
  /// the field-by-field fallback below).
  final bool command;

  /// Detect RELATIVE file paths (#1036). Default TRUE (purely additive):
  /// safe because a relpath anchor is INVISIBLE until its cwd-resolved
  /// absolute path passes the #990 SFTP-stat verification — turning the
  /// pattern on changes nothing visible for a token that doesn't resolve.
  final bool relpath;

  /// Whether the URL patterns should be registered (master AND url), UNLESS the
  /// #971 kill switch has force-disabled detection (see [kDetectionDisabled971]).
  bool get detectUrls => !kDetectionDisabled971 && enabled && url;

  /// Whether the path pattern should be registered (master AND path), UNLESS the
  /// #971 kill switch has force-disabled detection.
  bool get detectPaths => !kDetectionDisabled971 && enabled && path;

  /// Whether the command-line pattern should be registered (master AND command),
  /// under the same #971 kill switch (#998 slice C).
  bool get detectCommands => !kDetectionDisabled971 && enabled && command;

  /// Whether the RELATIVE-path pattern should be registered (master AND
  /// relpath), under the same #971 kill switch (#1036).
  bool get detectRelPaths => !kDetectionDisabled971 && enabled && relpath;

  /// Whether ANY pattern is registered — the single truth the terminal view's
  /// repaint gating reads (#921), instead of re-deriving boolean combinations
  /// per call site (#998 C added a third type; state-management rule).
  bool get detectionActive =>
      detectUrls || detectPaths || detectCommands || detectRelPaths;

  DetectionSettings copyWith({
    bool? enabled,
    bool? url,
    bool? path,
    bool? command,
    bool? relpath,
  }) {
    return DetectionSettings(
      schemaVersion: detectionSettingsSchemaVersion,
      enabled: enabled ?? this.enabled,
      url: url ?? this.url,
      path: path ?? this.path,
      command: command ?? this.command,
      relpath: relpath ?? this.relpath,
    );
  }

  /// Serialize to the persisted JSON shape:
  /// `{"v":1,"enabled":..,"url":..,"path":..,"command":..}`.
  String toJsonString() => jsonEncode(<String, dynamic>{
    'v': detectionSettingsSchemaVersion,
    'enabled': enabled,
    'url': url,
    'path': path,
    'command': command,
    'relpath': relpath,
  });

  /// Parse a stored JSON string, FIELD-BY-FIELD with a per-field default
  /// fallback. A null / non-JSON / non-object / wrong-version / corrupt value
  /// (or any non-bool field) falls back to the default for that field — it never
  /// throws and never returns "all off". Returns the all-true default for any
  /// input that can't be decoded at all.
  static DetectionSettings fromJsonString(String? raw) {
    if (raw == null) return const DetectionSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const DetectionSettings();
      bool field(String key, bool fallback) {
        final v = decoded[key];
        return v is bool ? v : fallback;
      }

      // The version is informational here (the shape is back-compatible field
      // reads), but we record it so a future migration can branch on it.
      final v = decoded['v'];
      const def = DetectionSettings();
      return DetectionSettings(
        schemaVersion: v is int ? v : detectionSettingsSchemaVersion,
        enabled: field('enabled', def.enabled),
        url: field('url', def.url),
        path: field('path', def.path),
        // Absent in pre-#998 stored values → defaults TRUE (additive).
        command: field('command', def.command),
        // Absent in pre-#1036 stored values → defaults TRUE (additive).
        relpath: field('relpath', def.relpath),
      );
    } catch (_) {
      // Corrupt / non-JSON value → safe all-true default (no silent disable).
      return const DetectionSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DetectionSettings &&
      other.schemaVersion == schemaVersion &&
      other.enabled == enabled &&
      other.url == url &&
      other.path == path &&
      other.command == command &&
      other.relpath == relpath;

  @override
  int get hashCode =>
      Object.hash(schemaVersion, enabled, url, path, command, relpath);

  @override
  String toString() =>
      'DetectionSettings(v:$schemaVersion, enabled:$enabled, url:$url, '
      'path:$path, command:$command, relpath:$relpath)';
}

/// Persisted GLOBAL detection settings (#888 Part A). Synchronous default
/// (all-true) while prefs hydrate so the terminal registers patterns
/// immediately on first build; a stored value re-applies on hydrate.
class DetectionSettingsNotifier extends StateNotifier<DetectionSettings> {
  DetectionSettingsNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(const DetectionSettings()) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getString(detectionSettingsPrefKey);
      if (stored != null) {
        final parsed = DetectionSettings.fromJsonString(stored);
        if (parsed != state) state = parsed;
      }
    } catch (_) {
      // best-effort; keep the all-true default if prefs unavailable (tests).
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(detectionSettingsPrefKey, state.toJsonString());
    } catch (_) {
      // best-effort persistence
    }
  }

  /// Toggle the master switch (when false, NO patterns are registered).
  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    await _persist();
  }

  /// Toggle URL detection (osc8 + url patterns).
  Future<void> setUrl(bool value) async {
    state = state.copyWith(url: value);
    await _persist();
  }

  /// Toggle file-path detection.
  Future<void> setPath(bool value) async {
    state = state.copyWith(path: value);
    await _persist();
  }

  /// Toggle command-line detection (#998 slice C).
  Future<void> setCommand(bool value) async {
    state = state.copyWith(command: value);
    await _persist();
  }

  /// Toggle RELATIVE-path detection (#1036).
  Future<void> setRelpath(bool value) async {
    state = state.copyWith(relpath: value);
    await _persist();
  }
}

/// Global detection-settings provider. Read at terminal pattern-registration
/// time and `ref.listen`-ed for live re-apply (clear + re-register).
final detectionSettingsProvider =
    StateNotifierProvider<DetectionSettingsNotifier, DetectionSettings>((ref) {
      return DetectionSettingsNotifier();
    });
