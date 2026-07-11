// #1036 — the RELATIVE-path detection toggle: a fourth per-type gate on
// DetectionSettings (default ON, purely additive) and its registration
// contract (`relpath` pattern registers iff master AND relpath are on).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DetectionSettings.relpath (#1036)', () {
    test('defaults ON (purely additive)', () {
      const s = DetectionSettings();
      expect(s.relpath, isTrue);
      expect(s.detectRelPaths, !kDetectionDisabled971);
    });

    test('master off gates relpath too', () {
      const s = DetectionSettings(enabled: false);
      expect(s.detectRelPaths, isFalse);
    });

    test('per-type off gates only relpath', () {
      const s = DetectionSettings(relpath: false);
      expect(s.detectRelPaths, isFalse);
      expect(s.detectPaths, !kDetectionDisabled971);
      expect(s.detectUrls, !kDetectionDisabled971);
    });

    test('relpath participates in detectionActive', () {
      const onlyRel = DetectionSettings(
        url: false,
        path: false,
        command: false,
      );
      expect(onlyRel.detectionActive, !kDetectionDisabled971);
      const allOff = DetectionSettings(
        url: false,
        path: false,
        command: false,
        relpath: false,
      );
      expect(allOff.detectionActive, isFalse);
    });

    test('JSON round-trip carries relpath', () {
      const s = DetectionSettings(relpath: false, url: false);
      final back = DetectionSettings.fromJsonString(s.toJsonString());
      expect(back, s);
      expect(back.relpath, isFalse);
    });

    test('a stored pre-#1036 value (no relpath field) defaults relpath TRUE',
        () {
      final s = DetectionSettings.fromJsonString(
        '{"v":1,"enabled":true,"url":false,"path":true,"command":true}',
      );
      expect(s.relpath, isTrue);
      expect(s.url, isFalse);
    });

    test('setRelpath persists and hydrates back', () async {
      final n =
          DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.setRelpath(false);
      expect(n.state.relpath, isFalse);
      final n2 =
          DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n2.state.relpath, isFalse);
      expect(n2.state.path, isTrue);
    });
  });

  group('ghosttyDetectionPatterns relpath registration (#1036)', () {
    test('relpath registers by default under its own id', () {
      final ids =
          ghosttyDetectionPatterns(const DetectionSettings()).map((p) => p.id);
      expect(ids, contains(kGhosttyRelPathPatternId));
    });

    test('relpath OFF removes only the relpath pattern', () {
      final ids = ghosttyDetectionPatterns(
        const DetectionSettings(relpath: false),
      ).map((p) => p.id).toList();
      expect(ids, isNot(contains(kGhosttyRelPathPatternId)));
      expect(ids, containsAll(<String>['osc8', 'url', 'path', 'command']));
    });

    test('master OFF removes relpath too', () {
      final ids = ghosttyDetectionPatterns(
        const DetectionSettings(enabled: false),
      ).map((p) => p.id);
      expect(ids, isEmpty);
    });
  });
}
