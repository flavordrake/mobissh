// #1031 slice 3 — user-defined pattern store.
//
// Locks the IA review's binding change 5: a custom pattern's id is minted
// ONCE at creation and NEVER re-derived from the name — renaming keeps the id
// stable so the style store, the enable bit, and the #995 exception family
// (all keyed by id) never orphan. Plus the standard storage contract:
// schema-in-value, corrupt→empty, bad entries dropped individually, and the
// defensive regex compile that can never throw.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<CustomPatternsStore> _store([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  return CustomPatternsStore(prefs: await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('id minting (IA review change 5)', () {
    test('mints ids in the custom. namespace', () {
      final id = mintCustomPatternId(const []);
      expect(id, startsWith(kCustomPatternIdPrefix));
      expect(isCustomPatternId(id), isTrue);
    });

    test('never collides with existing ids', () {
      final existing = <String>{};
      for (var i = 0; i < 5; i++) {
        final id = mintCustomPatternId(existing, nowMs: 1234567);
        expect(existing.contains(id), isFalse);
        existing.add(id);
      }
    });

    test('built-in ids are not custom', () {
      expect(isCustomPatternId('url'), isFalse);
      expect(isCustomPatternId('osc8'), isFalse);
      expect(isCustomPatternId('path'), isFalse);
      expect(isCustomPatternId('command'), isFalse);
    });
  });

  group('regex compile (safe failure)', () {
    test('valid source compiles', () {
      expect(compileCustomPatternRegex(r'[A-Z]{2,}-\d+'), isNotNull);
    });

    test('invalid source returns null, never throws', () {
      expect(compileCustomPatternRegex('('), isNull);
      expect(compileCustomPatternRegex(r'[a-'), isNull);
    });

    test('empty / whitespace source returns null', () {
      expect(compileCustomPatternRegex(''), isNull);
      expect(compileCustomPatternRegex('   '), isNull);
    });

    test('error text: message for invalid, null for valid', () {
      expect(customPatternRegexError(r'[A-Z]{2,}-\d+'), isNull);
      expect(customPatternRegexError('('), isNotNull);
    });
  });

  group('store round-trip', () {
    test('add → load preserves every field', () async {
      final store = await _store();
      final added = await store.add(
        name: 'Jira tickets',
        source: r'\b[A-Z]{2,}-\d+\b',
        sampleLine: 'fixed in PROJ-1234 yesterday',
      );
      expect(added.id, startsWith(kCustomPatternIdPrefix));
      expect(added.enabled, isTrue);

      final loaded = await store.load();
      expect(loaded, hasLength(1));
      final p = loaded.single;
      expect(p.id, added.id);
      expect(p.name, 'Jira tickets');
      expect(p.source, r'\b[A-Z]{2,}-\d+\b');
      expect(p.sampleLine, 'fixed in PROJ-1234 yesterday');
      expect(p.enabled, isTrue);
      expect(p.createdTs, greaterThan(0));
    });

    test('update (rename + regex edit) KEEPS the id', () async {
      final store = await _store();
      final added = await store.add(
        name: 'Jira tickets',
        source: r'\b[A-Z]{2,}-\d+\b',
        sampleLine: 'PROJ-1',
      );
      await store.update(
        added.id,
        name: 'Issue keys',
        source: r'[A-Z]+-\d+',
        sampleLine: 'ISS-2',
      );
      final loaded = await store.load();
      expect(loaded.single.id, added.id,
          reason: 'rename must NOT re-derive the id (review change 5)');
      expect(loaded.single.name, 'Issue keys');
      expect(loaded.single.source, r'[A-Z]+-\d+');
      expect(loaded.single.createdTs, added.createdTs);
    });

    test('setEnabled flips only the bit', () async {
      final store = await _store();
      final added = await store.add(name: 'x', source: r'\d+', sampleLine: '');
      await store.setEnabled(added.id, false);
      final loaded = await store.load();
      expect(loaded.single.enabled, isFalse);
      expect(loaded.single.source, r'\d+');
    });

    test('remove drops the record', () async {
      final store = await _store();
      final a = await store.add(name: 'a', source: r'\d+', sampleLine: '');
      final b = await store.add(name: 'b', source: r'\w+', sampleLine: '');
      await store.remove(a.id);
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, b.id);
    });

    test('two adds mint two distinct ids', () async {
      final store = await _store();
      final a = await store.add(name: 'a', source: r'\d+', sampleLine: '');
      final b = await store.add(name: 'b', source: r'\w+', sampleLine: '');
      expect(a.id, isNot(b.id));
    });
  });

  group('corrupt-resilience (validate → fallback, never crash)', () {
    test('non-JSON value → empty', () async {
      final store =
          await _store({customPatternsPrefsKey: 'not json at all {'});
      expect(await store.load(), isEmpty);
    });

    test('wrong shape → empty', () async {
      final store = await _store({customPatternsPrefsKey: '[1,2,3]'});
      expect(await store.load(), isEmpty);
    });

    test('unknown schema version → empty', () async {
      final store = await _store({
        customPatternsPrefsKey:
            jsonEncode({'v': 99, 'patterns': <Object>[]}),
      });
      expect(await store.load(), isEmpty);
    });

    test('bad entries dropped individually; good ones survive', () async {
      final store = await _store({
        customPatternsPrefsKey: jsonEncode({
          'v': 1,
          'patterns': [
            42,
            {'name': 'no id', 'source': r'\d+'},
            {
              'id': 'custom.p1',
              'name': 'good',
              'source': r'\d+',
              'enabled': true,
              'ts': 5,
            },
          ],
        }),
      });
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'custom.p1');
    });

    test('a stored INVALID regex still loads (the UI shows the error state; '
        'registration skips it)', () async {
      final store = await _store({
        customPatternsPrefsKey: jsonEncode({
          'v': 1,
          'patterns': [
            {
              'id': 'custom.p1',
              'name': 'broken',
              'source': '(',
              'enabled': true,
              'ts': 5,
            },
          ],
        }),
      });
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(compileCustomPatternRegex(loaded.single.source), isNull);
    });
  });
}
