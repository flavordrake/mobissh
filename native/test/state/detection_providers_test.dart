// Unit tests for the #888 Part A in-terminal detection settings.
//
// Locks the versioned-JSON persistence contract: default ALL TRUE (no
// regression), hydrate a stored value, a corrupt / wrong-shape value falling
// back FIELD-BY-FIELD to defaults (a stale pref must never crash or silently
// disable detection), and a set+persist round-trip writing the versioned shape.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settle() async {
  // Let the StateNotifier _hydrate Future resolve.
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DetectionSettings', () {
    test('defaults are all true (no regression)', () {
      const s = DetectionSettings();
      expect(s.enabled, isTrue);
      expect(s.url, isTrue);
      expect(s.path, isTrue);
      expect(s.command, isTrue);
      expect(s.schemaVersion, detectionSettingsSchemaVersion);
      // The stored prefs still default all-true; the effective getters follow
      // the #971 kill switch (force-disabled while it's set).
      expect(s.detectUrls, !kDetectionDisabled971);
      expect(s.detectPaths, !kDetectionDisabled971);
      expect(s.detectCommands, !kDetectionDisabled971);
    });

    test('#971 kill switch force-disables the getters regardless of prefs', () {
      const on = DetectionSettings(enabled: true, url: true, path: true);
      // While kDetectionDisabled971 is set, no prefs can turn detection on.
      expect(on.detectUrls, !kDetectionDisabled971);
      expect(on.detectPaths, !kDetectionDisabled971);
      // The raw prefs are PRESERVED (they return when the switch flips back).
      expect(on.enabled, isTrue);
      expect(on.url, isTrue);
      expect(on.path, isTrue);
    });

    test('master off gates url, path AND command registration', () {
      const s = DetectionSettings(
        enabled: false,
        url: true,
        path: true,
        command: true,
      );
      expect(s.detectUrls, isFalse);
      expect(s.detectPaths, isFalse);
      expect(s.detectCommands, isFalse);
      expect(s.detectionActive, isFalse);
    });

    test('per-type off gates only that type', () {
      const noUrl = DetectionSettings(url: false);
      expect(noUrl.detectUrls, isFalse);
      expect(noUrl.detectPaths, !kDetectionDisabled971);
      const noPath = DetectionSettings(path: false);
      expect(noPath.detectUrls, !kDetectionDisabled971);
      expect(noPath.detectPaths, isFalse);
      // #998 slice C: the command-line toggle is a third per-type gate.
      const noCommand = DetectionSettings(command: false);
      expect(noCommand.detectCommands, isFalse);
      expect(noCommand.detectUrls, !kDetectionDisabled971);
      expect(noCommand.detectPaths, !kDetectionDisabled971);
    });

    test('detectionActive is true while ANY type is registered (#998 C)', () {
      const onlyCommand = DetectionSettings(url: false, path: false);
      expect(onlyCommand.detectCommands, !kDetectionDisabled971);
      expect(onlyCommand.detectionActive, !kDetectionDisabled971);
      const allOff = DetectionSettings(url: false, path: false, command: false);
      expect(allOff.detectionActive, isFalse);
    });

    test('toJsonString emits the versioned shape', () {
      const s = DetectionSettings(
        enabled: true,
        url: false,
        path: true,
        command: false,
      );
      final decoded = jsonDecode(s.toJsonString()) as Map<String, dynamic>;
      expect(decoded['v'], detectionSettingsSchemaVersion);
      expect(decoded['enabled'], true);
      expect(decoded['url'], false);
      expect(decoded['path'], true);
      expect(decoded['command'], false);
    });

    test('fromJsonString round-trips a serialized value', () {
      const s = DetectionSettings(
        enabled: false,
        url: false,
        path: true,
        command: false,
      );
      final back = DetectionSettings.fromJsonString(s.toJsonString());
      expect(back, s);
    });

    test('a stored pre-#998 value (no command field) defaults command TRUE', () {
      // The v1 shape persisted before the command toggle existed must hydrate
      // with command detection ON (purely-additive setting, no regression).
      final s = DetectionSettings.fromJsonString(
        '{"v":1,"enabled":true,"url":false,"path":true}',
      );
      expect(s.command, isTrue);
      expect(s.url, isFalse);
    });

    group('fromJsonString fallback', () {
      test('null → all-true default', () {
        expect(DetectionSettings.fromJsonString(null), const DetectionSettings());
      });

      test('non-JSON garbage → all-true default', () {
        expect(
          DetectionSettings.fromJsonString('not json {{{'),
          const DetectionSettings(),
        );
      });

      test('JSON that is not an object → all-true default', () {
        expect(
          DetectionSettings.fromJsonString('[1,2,3]'),
          const DetectionSettings(),
        );
      });

      test('missing fields fall back to default per-field (not all-off)', () {
        // Only `enabled:false` present — url/path must default TRUE, not false.
        final s = DetectionSettings.fromJsonString('{"v":1,"enabled":false}');
        expect(s.enabled, isFalse);
        expect(s.url, isTrue);
        expect(s.path, isTrue);
      });

      test('non-bool field values fall back to default per-field', () {
        final s = DetectionSettings.fromJsonString(
          '{"v":1,"enabled":"yes","url":1,"path":false}',
        );
        expect(s.enabled, isTrue); // "yes" not a bool → default true
        expect(s.url, isTrue); // 1 not a bool → default true
        expect(s.path, isFalse); // valid bool honored
      });

      test('unknown/wrong version still reads back-compatible fields', () {
        final s = DetectionSettings.fromJsonString(
          '{"v":99,"enabled":false,"url":false,"path":false}',
        );
        expect(s.enabled, isFalse);
        expect(s.url, isFalse);
        expect(s.path, isFalse);
        expect(s.schemaVersion, 99);
      });
    });
  });

  group('DetectionSettingsNotifier', () {
    test('defaults to all-true with no stored value', () async {
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, const DetectionSettings());
      expect(n.state.detectUrls, !kDetectionDisabled971);
      expect(n.state.detectPaths, !kDetectionDisabled971);
    });

    test('hydrates a stored versioned value', () async {
      SharedPreferences.setMockInitialValues({
        detectionSettingsPrefKey:
            '{"v":1,"enabled":true,"url":false,"path":true}',
      });
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state.enabled, isTrue);
      expect(n.state.url, isFalse);
      expect(n.state.path, isTrue);
    });

    test('hydrate with a corrupt stored value keeps the all-true default',
        () async {
      SharedPreferences.setMockInitialValues({
        detectionSettingsPrefKey: 'corrupt {{{',
      });
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, const DetectionSettings());
    });

    test('setEnabled updates state and persists the versioned shape', () async {
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.setEnabled(false);
      expect(n.state.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(detectionSettingsPrefKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['v'], detectionSettingsSchemaVersion);
      expect(decoded['enabled'], false);
    });

    test('setUrl / setPath / setCommand persist independently (round-trip)',
        () async {
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.setUrl(false);
      await n.setPath(false);
      await n.setCommand(false);
      expect(n.state.url, isFalse);
      expect(n.state.path, isFalse);
      expect(n.state.command, isFalse);
      expect(n.state.enabled, isTrue);

      // A fresh notifier reading the persisted value sees the same state.
      final n2 =
          DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n2.state.url, isFalse);
      expect(n2.state.path, isFalse);
      expect(n2.state.command, isFalse);
      expect(n2.state.enabled, isTrue);
    });
  });
}
