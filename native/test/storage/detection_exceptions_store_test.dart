// Detection exceptions store (#995) — "Not a URL" / "Not a file" reports
// persisted as exact-match suppression records.
//
// Contract under test (favorites_store.dart precedent):
//   - round-trip: add → load returns the record with all fields
//   - dedupe: same (family, matchedText) added twice stores once
//   - url and osc8 share ONE family ('url'); path is its own
//   - remove restores (record gone from load)
//   - corrupt JSON / wrong shape / unknown schema version → empty (never throws)
//   - schema version lives INSIDE the value (no key bumping)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/detection_exceptions_store.dart';

Future<DetectionExceptionsStore> _store() async {
  final prefs = await SharedPreferences.getInstance();
  return DetectionExceptionsStore(prefs: prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('family mapping: url and osc8 share one family, path is its own', () {
    expect(detectionExceptionFamily('url'), 'url');
    expect(detectionExceptionFamily('osc8'), 'url');
    expect(detectionExceptionFamily('path'), 'path');
    // A future custom pattern id maps to itself.
    expect(detectionExceptionFamily('custom-regex-1'), 'custom-regex-1');
  });

  test('round-trip: add then load returns the full record', () async {
    final store = await _store();
    await store.add(
      const DetectionException(
        matchedText: 'https://example.com/x',
        patternId: 'url',
        contextLine: 'curl https://example.com/x failed',
        tsMs: 1720000000000,
        host: 'test-sshd',
      ),
    );

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    final e = loaded.single;
    expect(e.matchedText, 'https://example.com/x');
    expect(e.patternId, 'url');
    expect(e.contextLine, 'curl https://example.com/x failed');
    expect(e.tsMs, 1720000000000);
    expect(e.host, 'test-sshd');
    expect(e.scope, 'global');
  });

  test('dedupe: same family + matchedText stores once (osc8 == url)', () async {
    final store = await _store();
    await store.add(
      const DetectionException(matchedText: 'https://a.b/c', patternId: 'url'),
    );
    // Same text reported via the OSC-8 pattern — same family, deduped.
    await store.add(
      const DetectionException(matchedText: 'https://a.b/c', patternId: 'osc8'),
    );
    expect(await store.load(), hasLength(1));

    // Same text as a PATH is a different family — kept separately.
    await store.add(
      const DetectionException(matchedText: 'https://a.b/c', patternId: 'path'),
    );
    expect(await store.load(), hasLength(2));
  });

  test('remove by pattern family + text restores detection', () async {
    final store = await _store();
    await store.add(
      const DetectionException(matchedText: '/etc/hosts', patternId: 'path'),
    );
    await store.add(
      const DetectionException(matchedText: 'https://a.b', patternId: 'url'),
    );

    await store.remove(patternId: 'path', matchedText: '/etc/hosts');
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.matchedText, 'https://a.b');
  });

  test('corrupt JSON falls back to empty (never throws)', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      detectionExceptionsPrefsKey: '{not json',
    });
    final store = await _store();
    expect(await store.load(), isEmpty);
  });

  test('wrong shape falls back to empty', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      detectionExceptionsPrefsKey: jsonEncode(['not', 'a', 'map']),
    });
    final store = await _store();
    expect(await store.load(), isEmpty);
  });

  test('unknown schema version falls back to empty (version-in-value)', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      detectionExceptionsPrefsKey: jsonEncode({
        'v': 999,
        'entries': [
          {'text': 'https://a.b', 'pattern': 'url'},
        ],
      }),
    });
    final store = await _store();
    expect(await store.load(), isEmpty);
  });

  test('bad entries are dropped, good entries survive', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      detectionExceptionsPrefsKey: jsonEncode({
        'v': 1,
        'entries': [
          {'text': 'https://good.example', 'pattern': 'url'},
          {'pattern': 'url'}, // no text → dropped
          'garbage', // not a map → dropped
          {'text': '', 'pattern': 'url'}, // empty text → dropped
        ],
      }),
    });
    final store = await _store();
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.matchedText, 'https://good.example');
  });

  test('blank matched text is rejected (no-op add)', () async {
    final store = await _store();
    await store.add(
      const DetectionException(matchedText: '   ', patternId: 'url'),
    );
    expect(await store.load(), isEmpty);
  });
}
