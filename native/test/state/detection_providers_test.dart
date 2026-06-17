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
      expect(s.schemaVersion, detectionSettingsSchemaVersion);
      expect(s.detectUrls, isTrue);
      expect(s.detectPaths, isTrue);
    });

    test('master off gates both url and path registration', () {
      const s = DetectionSettings(enabled: false, url: true, path: true);
      expect(s.detectUrls, isFalse);
      expect(s.detectPaths, isFalse);
    });

    test('per-type off gates only that type', () {
      const noUrl = DetectionSettings(url: false);
      expect(noUrl.detectUrls, isFalse);
      expect(noUrl.detectPaths, isTrue);
      const noPath = DetectionSettings(path: false);
      expect(noPath.detectUrls, isTrue);
      expect(noPath.detectPaths, isFalse);
    });

    test('toJsonString emits the versioned shape', () {
      const s = DetectionSettings(enabled: true, url: false, path: true);
      final decoded = jsonDecode(s.toJsonString()) as Map<String, dynamic>;
      expect(decoded['v'], detectionSettingsSchemaVersion);
      expect(decoded['enabled'], true);
      expect(decoded['url'], false);
      expect(decoded['path'], true);
    });

    test('fromJsonString round-trips a serialized value', () {
      const s = DetectionSettings(enabled: false, url: false, path: true);
      final back = DetectionSettings.fromJsonString(s.toJsonString());
      expect(back, s);
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
      expect(n.state.detectUrls, isTrue);
      expect(n.state.detectPaths, isTrue);
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

    test('setUrl / setPath persist independently (round-trip)', () async {
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.setUrl(false);
      await n.setPath(false);
      expect(n.state.url, isFalse);
      expect(n.state.path, isFalse);
      expect(n.state.enabled, isTrue);

      // A fresh notifier reading the persisted value sees the same state.
      final n2 =
          DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n2.state.url, isFalse);
      expect(n2.state.path, isFalse);
      expect(n2.state.enabled, isTrue);
    });
  });
}
