// Unit tests for the #888 Part A in-terminal detection settings.
//
// Locks the versioned-JSON persistence contract: default ALL TRUE (no
// regression), hydrate a stored value, a corrupt / wrong-shape value falling
// back FIELD-BY-FIELD to defaults (a stale pref must never crash or silently
// disable detection), and a set+persist round-trip writing the versioned shape.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      // #1036 added a fourth type — "all off" must turn it off too.
      const allOff = DetectionSettings(
        url: false,
        path: false,
        command: false,
        relpath: false,
      );
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

  // #1154 (Slice 1 of #1153) — link highlight OPTIONS: three additive fields
  // (intensity, gutterSide, gutterMode) persisted in the SAME versioned JSON
  // value (R7/R8). Same field-by-field hydrate rule as command/relpath: a
  // pre-#1154 stored value and any corrupt enum value fall back to THAT
  // field's default only — the other fields in the same JSON survive.
  group('#1154 link highlight options (R7/R8)', () {
    test('R7: defaults are medium / right / overlay (zero visual change)', () {
      const s = DetectionSettings();
      expect(s.intensity, DetectionIntensity.medium);
      expect(s.gutterSide, GutterSide.right);
      expect(s.gutterMode, GutterMode.overlay);
    });

    test('R8: the schema version stays 1 — additive fields, no bump', () {
      expect(detectionSettingsSchemaVersion, 1);
      expect(detectionSettingsPrefKey, 'mobissh.detection.settings');
    });

    test('R7: copyWith accepts the three fields and keeps the others', () {
      const base = DetectionSettings(url: false);
      final s = base.copyWith(
        intensity: DetectionIntensity.high,
        gutterSide: GutterSide.left,
        gutterMode: GutterMode.column,
      );
      expect(s.intensity, DetectionIntensity.high);
      expect(s.gutterSide, GutterSide.left);
      expect(s.gutterMode, GutterMode.column);
      expect(s.url, isFalse, reason: 'unrelated fields carried over');
      // Absent args keep the receiver's values.
      final same = s.copyWith(enabled: false);
      expect(same.intensity, DetectionIntensity.high);
      expect(same.gutterSide, GutterSide.left);
      expect(same.gutterMode, GutterMode.column);
    });

    test('R7: toJsonString stores the enum NAME under intensity / gutterSide / '
        'gutterMode', () {
      const s = DetectionSettings(
        intensity: DetectionIntensity.low,
        gutterSide: GutterSide.left,
        gutterMode: GutterMode.column,
      );
      final decoded = jsonDecode(s.toJsonString()) as Map<String, dynamic>;
      expect(decoded['v'], 1);
      expect(decoded['intensity'], 'low');
      expect(decoded['gutterSide'], 'left');
      expect(decoded['gutterMode'], 'column');
    });

    test('R7: fromJsonString round-trips all three (non-default values)', () {
      const s = DetectionSettings(
        enabled: false,
        intensity: DetectionIntensity.high,
        gutterSide: GutterSide.left,
        gutterMode: GutterMode.column,
      );
      final back = DetectionSettings.fromJsonString(s.toJsonString());
      expect(back, s);
      expect(back.intensity, DetectionIntensity.high);
      expect(back.gutterSide, GutterSide.left);
      expect(back.gutterMode, GutterMode.column);
    });

    test('R7: equality and hashCode include the three fields', () {
      const a = DetectionSettings();
      const b = DetectionSettings(intensity: DetectionIntensity.low);
      const c = DetectionSettings(gutterSide: GutterSide.left);
      const d = DetectionSettings(gutterMode: GutterMode.column);
      expect(a, isNot(equals(b)));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
      expect(const DetectionSettings(intensity: DetectionIntensity.low), b);
      expect(
        const DetectionSettings(intensity: DetectionIntensity.low).hashCode,
        b.hashCode,
      );
    });

    test('R8: a pre-#1154 v1 value (no option fields) hydrates the three '
        'fields to defaults with the other fields intact', () {
      final s = DetectionSettings.fromJsonString(
        '{"v":1,"enabled":true,"url":false,"path":true,"command":false,'
        '"relpath":true}',
      );
      expect(s.intensity, DetectionIntensity.medium);
      expect(s.gutterSide, GutterSide.right);
      expect(s.gutterMode, GutterMode.overlay);
      // The existing fields are untouched by the additive read.
      expect(s.enabled, isTrue);
      expect(s.url, isFalse);
      expect(s.path, isTrue);
      expect(s.command, isFalse);
      expect(s.relpath, isTrue);
      expect(s.schemaVersion, 1);
    });

    test('R8: an unknown enum name ("ultra") falls back to medium while '
        'enabled:false in the same JSON is KEPT', () {
      final s = DetectionSettings.fromJsonString(
        '{"v":1,"enabled":false,"intensity":"ultra"}',
      );
      expect(s.intensity, DetectionIntensity.medium);
      expect(s.enabled, isFalse, reason: 'field-by-field: a bad sibling never '
          'resets a valid field');
    });

    test('R8: a non-string enum value ("gutterSide":42) falls back to right',
        () {
      final s = DetectionSettings.fromJsonString(
        '{"v":1,"gutterSide":42,"intensity":"high"}',
      );
      expect(s.gutterSide, GutterSide.right);
      expect(s.intensity, DetectionIntensity.high, reason: 'valid sibling kept');
    });

    test('R8: a null enum value ("gutterMode":null) falls back to overlay', () {
      final s = DetectionSettings.fromJsonString(
        '{"v":1,"gutterMode":null,"gutterSide":"left"}',
      );
      expect(s.gutterMode, GutterMode.overlay);
      expect(s.gutterSide, GutterSide.left, reason: 'valid sibling kept');
    });

    test('R8: every valid enum name reads back (case-exact names)', () {
      for (final level in DetectionIntensity.values) {
        final s = DetectionSettings.fromJsonString(
          '{"v":1,"intensity":"${level.name}"}',
        );
        expect(s.intensity, level);
      }
      for (final side in GutterSide.values) {
        final s = DetectionSettings.fromJsonString(
          '{"v":1,"gutterSide":"${side.name}"}',
        );
        expect(s.gutterSide, side);
      }
      for (final mode in GutterMode.values) {
        final s = DetectionSettings.fromJsonString(
          '{"v":1,"gutterMode":"${mode.name}"}',
        );
        expect(s.gutterMode, mode);
      }
    });

    test('R7: setIntensity / setGutterSide / setGutterMode persist and '
        'rehydrate through a fresh notifier', () async {
      final n = DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.setIntensity(DetectionIntensity.low);
      await n.setGutterSide(GutterSide.left);
      await n.setGutterMode(GutterMode.column);
      expect(n.state.intensity, DetectionIntensity.low);
      expect(n.state.gutterSide, GutterSide.left);
      expect(n.state.gutterMode, GutterMode.column);
      expect(n.state.enabled, isTrue, reason: 'setters never touch enabled');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(detectionSettingsPrefKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['v'], 1);
      expect(decoded['intensity'], 'low');
      expect(decoded['gutterSide'], 'left');
      expect(decoded['gutterMode'], 'column');

      final n2 =
          DetectionSettingsNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n2.state.intensity, DetectionIntensity.low);
      expect(n2.state.gutterSide, GutterSide.left);
      expect(n2.state.gutterMode, GutterMode.column);
    });

    test('R7: the option fields never change the registration getters', () {
      const s = DetectionSettings(
        intensity: DetectionIntensity.low,
        gutterSide: GutterSide.left,
        gutterMode: GutterMode.column,
      );
      expect(s.detectUrls, !kDetectionDisabled971);
      expect(s.detectPaths, !kDetectionDisabled971);
      expect(s.detectCommands, !kDetectionDisabled971);
      expect(s.detectRelPaths, !kDetectionDisabled971);
      expect(s.detectionActive, !kDetectionDisabled971);
    });
  });

  // #1154 A6 / R10 — the terminal view's re-register listener MUST select on
  // the pattern-relevant PROJECTION (enabled, url, path, command, relpath) so
  // a pure-visual change (intensity / side / mode) never clears + rescans the
  // patterns. No existing test pumps GhosttyTerminalView (it needs a live
  // session), so the seam is pinned here at the provider level: the view
  // subscribes via `detectionSettingsProvider.select((s) => s.patternProjection)`.
  group('#1154 R10 patternProjection (A6)', () {
    test('two settings differing ONLY by an option field have EQUAL '
        'projections', () {
      const base = DetectionSettings();
      const low = DetectionSettings(intensity: DetectionIntensity.low);
      const left = DetectionSettings(gutterSide: GutterSide.left);
      const column = DetectionSettings(gutterMode: GutterMode.column);
      expect(low.patternProjection, base.patternProjection);
      expect(left.patternProjection, base.patternProjection);
      expect(column.patternProjection, base.patternProjection);
      expect(low.patternProjection.hashCode, base.patternProjection.hashCode);
    });

    test('a change of any pattern-relevant field changes the projection', () {
      const base = DetectionSettings();
      expect(
        const DetectionSettings(enabled: false).patternProjection,
        isNot(equals(base.patternProjection)),
      );
      expect(
        const DetectionSettings(url: false).patternProjection,
        isNot(equals(base.patternProjection)),
      );
      expect(
        const DetectionSettings(path: false).patternProjection,
        isNot(equals(base.patternProjection)),
      );
      expect(
        const DetectionSettings(command: false).patternProjection,
        isNot(equals(base.patternProjection)),
      );
      expect(
        const DetectionSettings(relpath: false).patternProjection,
        isNot(equals(base.patternProjection)),
      );
    });

    test('a provider listener selected on patternProjection does NOT fire on '
        'setIntensity / setGutterSide / setGutterMode but DOES on setUrl',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Touch the provider so the notifier exists and has hydrated.
      container.read(detectionSettingsProvider);
      await _settle();

      var fired = 0;
      container.listen(
        detectionSettingsProvider.select((s) => s.patternProjection),
        (prev, next) => fired++,
      );

      final notifier = container.read(detectionSettingsProvider.notifier);
      await notifier.setIntensity(DetectionIntensity.high);
      await notifier.setGutterSide(GutterSide.left);
      await notifier.setGutterMode(GutterMode.column);
      expect(fired, 0, reason: 'visual-only changes must not rescan (R10)');

      await notifier.setUrl(false);
      expect(fired, 1, reason: 'a pattern-set change must re-register');

      await notifier.setEnabled(false);
      expect(fired, 2);
    });

    test('the un-selected provider DOES notify on setIntensity (so the seam '
        'is the select, not a silent notifier)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(detectionSettingsProvider);
      await _settle();

      var fired = 0;
      container.listen(detectionSettingsProvider, (prev, next) => fired++);
      await container
          .read(detectionSettingsProvider.notifier)
          .setIntensity(DetectionIntensity.low);
      expect(fired, 1, reason: 'the wash/gutter rebuild path still rides the '
          'plain watch');
    });
  });
}
