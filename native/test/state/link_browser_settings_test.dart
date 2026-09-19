// #1197 (slice 2 of #1195) — the GLOBAL default browser setting. Spec:
// `docs/link-browser-routing.md` R6, test A9.
//
// It lives in the EXISTING detection-settings JSON (the one value that already
// carries every link/detection preference): additive field, no new prefs key,
// no schema-version bump, corrupt value → System default
// (.claude/rules/code-style.md).
//
// PINNED API:
//   DetectionSettings({..., String? linkBrowserPackage})
//   DetectionSettings.copyWith({..., String? linkBrowserPackage,
//                               bool clearLinkBrowserPackage = false})
//   DetectionSettingsNotifier.setLinkBrowserPackage(String? package)

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/detection_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('A9 DetectionSettings.linkBrowserPackage (R6)', () {
    test('defaults to null = the system default', () {
      expect(const DetectionSettings().linkBrowserPackage, isNull);
    });

    test('JSON round-trip carries the package', () {
      const s = DetectionSettings(linkBrowserPackage: 'com.android.chrome');
      final back = DetectionSettings.fromJsonString(s.toJsonString());
      expect(back.linkBrowserPackage, 'com.android.chrome');
      expect(back, s);
    });

    test('null is omitted from the JSON (purely additive)', () {
      expect(
        const DetectionSettings().toJsonString().contains('linkBrowserPackage'),
        isFalse,
      );
    });

    test('a pre-#1197 stored value hydrates to the system default', () {
      const legacy =
          '{"v":1,"enabled":true,"url":true,"path":true,"command":true}';
      expect(DetectionSettings.fromJsonString(legacy).linkBrowserPackage, isNull);
    });

    test('a corrupt (non-string) value reads back as the default', () {
      const raw = '{"v":1,"linkBrowserPackage":42}';
      final s = DetectionSettings.fromJsonString(raw);
      expect(s.linkBrowserPackage, isNull);
      // ... and the OTHER fields still hydrate to their defaults (no crash,
      // no silent disable).
      expect(s.enabled, isTrue);
      expect(s.url, isTrue);
    });

    test('an empty-string value reads back as the default', () {
      const raw = '{"v":1,"linkBrowserPackage":""}';
      expect(
        DetectionSettings.fromJsonString(raw).linkBrowserPackage,
        isNull,
      );
    });

    test('copyWith sets, carries and clears the package', () {
      const s = DetectionSettings(linkBrowserPackage: 'com.work.prisma');
      expect(s.copyWith(url: false).linkBrowserPackage, 'com.work.prisma');
      expect(
        s.copyWith(linkBrowserPackage: 'com.android.chrome').linkBrowserPackage,
        'com.android.chrome',
      );
      expect(s.copyWith(clearLinkBrowserPackage: true).linkBrowserPackage,
          isNull);
    });
  });

  group('A9 persistence through the notifier', () {
    test('setLinkBrowserPackage persists and re-hydrates', () async {
      final notifier = DetectionSettingsNotifier();
      await notifier.setLinkBrowserPackage('com.work.prisma');
      expect(notifier.state.linkBrowserPackage, 'com.work.prisma');

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(detectionSettingsPrefKey);
      expect(stored, isNotNull);
      expect(
        DetectionSettings.fromJsonString(stored).linkBrowserPackage,
        'com.work.prisma',
      );

      // A fresh notifier over the same prefs hydrates the stored choice.
      final revived = DetectionSettingsNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(revived.state.linkBrowserPackage, 'com.work.prisma');
    });

    test('setLinkBrowserPackage(null) returns to the system default', () async {
      final notifier = DetectionSettingsNotifier();
      await notifier.setLinkBrowserPackage('com.work.prisma');
      await notifier.setLinkBrowserPackage(null);
      expect(notifier.state.linkBrowserPackage, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(
        DetectionSettings.fromJsonString(
          prefs.getString(detectionSettingsPrefKey),
        ).linkBrowserPackage,
        isNull,
      );
    });

    test('no prefs key is added — the existing settings value carries it',
        () async {
      final notifier = DetectionSettingsNotifier();
      await notifier.setLinkBrowserPackage('com.work.prisma');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), <String>{detectionSettingsPrefKey});
    });
  });
}
