// #1257: bug reports carry a `settings` snapshot so the next settings cleanup
// rests on usage data. It is an ALLOWLIST of non-secret UI prefs and feature
// flags: profiles, hosts, usernames, keys and passwords never appear, even when
// they sit in the same SharedPreferences store.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/settings_snapshot.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/feature_flags_providers.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/ui/feedback_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secretShaped = <String, Object>{
  'mobissh.profiles': '[{"host":"10.0.0.5","username":"root"}]',
  keysPrefsKey: '[{"id":"k1","name":"work"}]',
  'mobissh.password': 'hunter2',
  'mobissh.ui.privateKey': '-----BEGIN OPENSSH PRIVATE KEY-----',
  'mobissh.ui.passphrase': 'swordfish',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('picks allowlisted prefs and decodes the JSON-valued ones', () {
    final snap = buildSettingsSnapshot(<String, Object?>{
      fontSizePrefKey: 15.0,
      fontFamilyPrefKey: 'FiraCode',
      keepaliveEnabledPrefKey: true,
      tmuxControlModePrefKey: true,
      detectionSettingsPrefKey: '{"v":1,"enabled":true,"url":false}',
      featureFlagsPrefKey: '{"v":1,"showExperimental":false}',
    });
    expect(snap[fontSizePrefKey], 15.0);
    expect(snap[fontFamilyPrefKey], 'FiraCode');
    expect(snap[keepaliveEnabledPrefKey], isTrue);
    expect(snap[tmuxControlModePrefKey], isTrue);
    expect(snap[detectionSettingsPrefKey], {
      'v': 1,
      'enabled': true,
      'url': false,
    });
    expect(snap[featureFlagsPrefKey], {'v': 1, 'showExperimental': false});
  });

  test('a secret-shaped or unknown pref is never included', () {
    final snap = buildSettingsSnapshot(<String, Object?>{
      fontSizePrefKey: 13.0,
      ..._secretShaped,
    });
    expect(snap.keys, [fontSizePrefKey]);
    final flat = snap.toString();
    for (final v in const ['10.0.0.5', 'root', 'hunter2', 'swordfish',
        'PRIVATE KEY', 'work']) {
      expect(flat, isNot(contains(v)), reason: v);
    }
  });

  test('every allowlisted key is a mobissh UI/behaviour pref, none secret', () {
    for (final k in kSettingsSnapshotKeys) {
      expect(k, startsWith('mobissh.'));
      expect(
        k.toLowerCase(),
        isNot(matches(RegExp('pass|secret|key|profile|host|user|token'))),
        reason: k,
      );
    }
  });

  test('corrupt JSON values are kept as their raw string, no throw', () {
    final snap = buildSettingsSnapshot(<String, Object?>{
      featureFlagsPrefKey: '{broken',
    });
    expect(snap[featureFlagsPrefKey], '{broken');
  });

  test('reads from SharedPreferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      fontSizePrefKey: 18.0,
      ..._secretShaped,
    });
    final snap = await settingsSnapshot(prefs: SharedPreferences.getInstance());
    expect(snap, {fontSizePrefKey: 18.0});
  });

  test('the feedback payload carries the snapshot under `settings`', () {
    final payload = buildFeedbackPayload(
      comment: 'x',
      version: 'v',
      settings: const {fontSizePrefKey: 18.0},
    );
    expect(payload['settings'], {fontSizePrefKey: 18.0});
  });

  test('excluding traces excludes the snapshot too', () {
    final payload = buildFeedbackPayload(
      comment: 'x',
      version: 'v',
      settings: const {fontSizePrefKey: 18.0},
      includeTraces: false,
    );
    expect(payload.containsKey('settings'), isFalse);
  });
}
