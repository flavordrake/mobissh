// #1031 slice 1 — the detection STYLE store: per-pattern style overrides
// (colorHex / inactiveIntensity / activeIntensity) keyed by plain-string
// pattern id. Follows the favorites_store / detection_exceptions_store
// precedent: one JSON blob in shared_preferences, schema version INSIDE the
// value, corrupt / unknown-version → empty (never crash, never a key bump).
//
// Defaults are ABSENT: an empty store means the runtime keeps today's derived
// values exactly (the zero-visual-change invariant is asserted in
// detection_style_resolver_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DetectionStylesStore> storeWith(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    return DetectionStylesStore(prefs: prefs);
  }

  group('round-trip', () {
    test('an untouched store loads EMPTY (all defaults absent)', () async {
      final store = await storeWith({});
      final styles = await store.load();
      expect(styles.isEmpty, isTrue);
      expect(styles.of('url'), isNull);
      expect(styles.of('path'), isNull);
    });

    test('a stored override round-trips field-for-field', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'path',
        const DetectionPatternStyle(
          colorHex: '#33AA55',
          inactiveIntensity: 0.8,
          activeIntensity: 1.4,
        ),
      );
      final styles = await store.load();
      final path = styles.of('path');
      expect(path, isNotNull);
      expect(path!.colorHex, '#33AA55');
      expect(path.inactiveIntensity, 0.8);
      expect(path.activeIntensity, 1.4);
      // Other patterns stay absent.
      expect(styles.of('url'), isNull);
    });

    test('partial overrides round-trip with the other fields ABSENT', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'url',
        const DetectionPatternStyle(inactiveIntensity: 1.25),
      );
      final url = (await store.load()).of('url');
      expect(url!.colorHex, isNull);
      expect(url.inactiveIntensity, 1.25);
      expect(url.activeIntensity, isNull);
    });

    test('setting an EMPTY style removes the entry (absent = default)',
        () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'url',
        const DetectionPatternStyle(colorHex: '#FF0000'),
      );
      await store.setPatternStyle('url', const DetectionPatternStyle());
      expect((await store.load()).of('url'), isNull);
    });

    test('store keys are PLAIN STRINGS — a custom.* id round-trips', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'custom.jira-tickets',
        const DetectionPatternStyle(colorHex: '#AA00FF'),
      );
      final styles = await store.load();
      expect(styles.of('custom.jira-tickets')!.colorHex, '#AA00FF');
    });
  });

  group('corrupt-data resilience (validate → fallback, never crash)', () {
    test('non-JSON garbage → empty', () async {
      final store = await storeWith({detectionStylesPrefsKey: 'not json {'});
      expect((await store.load()).isEmpty, isTrue);
    });

    test('a JSON list instead of an object → empty', () async {
      final store = await storeWith({detectionStylesPrefsKey: '[1,2,3]'});
      expect((await store.load()).isEmpty, isTrue);
    });

    test('unknown FUTURE schema version → empty (never misread)', () async {
      final store = await storeWith({
        detectionStylesPrefsKey: '{"v":99,"styles":{"url":{"color":"#FF0000"}}}',
      });
      expect((await store.load()).isEmpty, isTrue);
    });

    test('a malformed entry is DROPPED, good entries survive', () async {
      final store = await storeWith({
        detectionStylesPrefsKey:
            '{"v":1,"styles":{"url":"nope","path":{"color":"#33AA55"},'
            '"osc8":{"inactive":"loud"}}}',
      });
      final styles = await store.load();
      expect(styles.of('url'), isNull, reason: 'non-map entry dropped');
      expect(styles.of('path')!.colorHex, '#33AA55');
      expect(
        styles.of('osc8'),
        isNull,
        reason: 'entry with only invalid-typed fields is dropped',
      );
    });

    test('a corrupt store recovers on the next write', () async {
      final store = await storeWith({detectionStylesPrefsKey: '{{{{'});
      await store.setPatternStyle(
        'command',
        const DetectionPatternStyle(inactiveIntensity: 0.5),
      );
      expect((await store.load()).of('command')!.inactiveIntensity, 0.5);
    });
  });

  group('behavior knobs (#1031 slice 2: verifyShortPaths + lexicon)', () {
    test('knob fields round-trip alongside style fields', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'path',
        const DetectionPatternStyle(verifyShortPaths: false),
      );
      await store.setPatternStyle(
        'command',
        const DetectionPatternStyle(lexicon: ['git', 'kubectl']),
      );
      final styles = await store.load();
      expect(styles.of('path')!.verifyShortPaths, isFalse);
      expect(styles.of('path')!.colorHex, isNull);
      expect(styles.of('command')!.lexicon, ['git', 'kubectl']);
    });

    test('a knob-only style is NOT empty; clearing the knob removes the entry',
        () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'path',
        const DetectionPatternStyle(verifyShortPaths: false),
      );
      expect((await store.load()).of('path'), isNotNull);
      await store.setPatternStyle('path', const DetectionPatternStyle());
      expect((await store.load()).of('path'), isNull);
    });

    test('wrong-typed knob fields are dropped field-by-field', () async {
      final store = await storeWith({
        detectionStylesPrefsKey:
            '{"v":1,"styles":{"path":{"color":"#33AA55","verify":"nope"},'
            '"command":{"lexicon":[1,2],"inactive":0.8}}}',
      });
      final styles = await store.load();
      expect(styles.of('path')!.colorHex, '#33AA55');
      expect(styles.of('path')!.verifyShortPaths, isNull,
          reason: 'non-bool verify dropped');
      expect(styles.of('command')!.inactiveIntensity, 0.8);
      expect(styles.of('command')!.lexicon, isNull,
          reason: 'non-string lexicon entries drop the list');
    });

    test('resetPattern clears knobs too (knobs are TUNED data)', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'command',
        const DetectionPatternStyle(lexicon: ['git']),
      );
      await store.resetPattern('command');
      expect((await store.load()).of('command'), isNull);
    });
  });

  group('reset seams (#1031 IA review: per-pattern + lab-wide)', () {
    test('resetPattern removes ONE pattern, leaves the rest', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'url',
        const DetectionPatternStyle(colorHex: '#FF0000'),
      );
      await store.setPatternStyle(
        'path',
        const DetectionPatternStyle(activeIntensity: 1.5),
      );
      await store.resetPattern('url');
      final styles = await store.load();
      expect(styles.of('url'), isNull);
      expect(styles.of('path'), isNotNull);
    });

    test('clearAllTuned removes EVERY override (the settings-reset seam — '
        'implemented now, wired in the lab slice)', () async {
      final store = await storeWith({});
      await store.setPatternStyle(
        'url',
        const DetectionPatternStyle(colorHex: '#FF0000'),
      );
      await store.setPatternStyle(
        'custom.x',
        const DetectionPatternStyle(inactiveIntensity: 1.2),
      );
      await store.clearAllTuned();
      expect((await store.load()).isEmpty, isTrue);
    });
  });
}
