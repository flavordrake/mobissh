// Unit tests for [ProfilesStore] (#501).
//
// Covers:
//   - load/save round-trip preserves identity + theme/color
//   - importFromJson with the PWA's envelope shape
//   - importFromJson with the legacy bare-array shape (forward-compat)
//   - dedupe on (host:port:username)
//   - invalid JSON / wrong shape returns ImportResult with errors, no crash
//   - rejects unknown export version

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Reset to a clean prefs map for every test. Empty initial values give
    // every test its own SharedPreferences instance.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedProfile', () {
    test('identityKey is host:port:username', () {
      final p = SavedProfile(
        title: 't', host: 'h.example', port: 2222, username: 'u',
      );
      expect(p.identityKey, 'h.example:2222:u');
    });

    test('toJson omits null theme/color', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      final json = p.toJson();
      expect(json.containsKey('theme'), isFalse);
      expect(json.containsKey('color'), isFalse);
    });

    test('toJson includes theme/color when present', () {
      final p = SavedProfile(
        title: 't', host: 'h', port: 22, username: 'u',
        theme: 'nord', color: '#abcdef',
      );
      expect(p.toJson()['theme'], 'nord');
      expect(p.toJson()['color'], '#abcdef');
    });

    test('fromJson throws FormatException for missing host', () {
      expect(
        () => SavedProfile.fromJson(<String, dynamic>{'username': 'u'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException for missing username', () {
      expect(
        () => SavedProfile.fromJson(<String, dynamic>{'host': 'h'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson defaults port to 22 when missing', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h.example', 'username': 'u',
      });
      expect(p.port, 22);
    });

    test('fromJson clamps invalid port to 22', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h', 'username': 'u', 'port': -1,
      });
      expect(p.port, 22);
    });

    test('fromJson synthesizes title from username@host when missing', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h.example', 'username': 'me', 'port': 22,
      });
      expect(p.title, 'me@h.example');
    });

    test('equality is by identity tuple (host, port, username)', () {
      final a = SavedProfile(
        title: 'A', host: 'h', port: 22, username: 'u', theme: 'dark',
      );
      final b = SavedProfile(
        title: 'B (different)', host: 'h', port: 22, username: 'u',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('ProfilesStore.load/save', () {
    test('load returns empty list when storage is empty', () async {
      final store = ProfilesStore();
      final loaded = await store.load();
      expect(loaded, isEmpty);
    });

    test('save+load round-trip preserves all fields', () async {
      final store = ProfilesStore();
      final original = <SavedProfile>[
        SavedProfile(
          title: 'Dev', host: 'dev.example', port: 22, username: 'admin',
          theme: 'dark', color: '#ff8800',
        ),
        SavedProfile(
          title: 'Prod', host: 'prod.example', port: 2222, username: 'deploy',
        ),
      ];
      await store.save(original);

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      expect(loaded[0].title, 'Dev');
      expect(loaded[0].host, 'dev.example');
      expect(loaded[0].port, 22);
      expect(loaded[0].username, 'admin');
      expect(loaded[0].theme, 'dark');
      expect(loaded[0].color, '#ff8800');
      expect(loaded[1].theme, isNull);
      expect(loaded[1].color, isNull);
    });

    test('load is corrupt-resilient — returns [] on malformed JSON',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        profilesPrefsKey: 'not json',
      });
      final store = ProfilesStore();
      final loaded = await store.load();
      expect(loaded, isEmpty);
    });

    test('load tolerates a corrupt entry mixed with valid ones', () async {
      // Pre-seed prefs with one bad + one good entry. The bad entry is
      // missing the required `host` field; the good entry should still
      // appear in the result.
      final raw = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'username': 'u'},
        <String, dynamic>{
          'host': 'good.example', 'username': 'u', 'port': 22, 'title': 'OK',
        },
      ]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        profilesPrefsKey: raw,
      });
      final store = ProfilesStore();
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded[0].host, 'good.example');
    });

    test('remove deletes the matching profile', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
        SavedProfile(title: 'B', host: 'b', port: 22, username: 'u2'),
      ]);
      await store.remove(host: 'a', port: 22, username: 'u1');
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.first.host, 'b');
    });
  });

  group('ProfilesStore.importFromJson — PWA envelope shape', () {
    // A realistic export captured from the PWA's exportProfilesJson(). The
    // native client MUST parse this without changes; it's the contract.
    const pwaExportFixture = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    {
      "title": "Home NAS",
      "host": "nas.tail123.ts.net",
      "port": 22,
      "username": "mfrazier",
      "theme": "dark",
      "color": "#88ccff"
    },
    {
      "title": "Build box",
      "host": "build.tail123.ts.net",
      "port": 2222,
      "username": "ci",
      "theme": "nord"
    }
  ]
}
''';

    test('imports both profiles from a fresh store', () async {
      final store = ProfilesStore();
      final result = await store.importFromJson(pwaExportFixture);
      expect(result.added, 2);
      expect(result.skipped, 0);
      expect(result.errors, isEmpty);

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      expect(loaded[0].title, 'Home NAS');
      expect(loaded[0].color, '#88ccff');
      expect(loaded[1].title, 'Build box');
      expect(loaded[1].theme, 'nord');
    });

    test('dedupes on (host:port:username) when re-importing', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Old Name', host: 'nas.tail123.ts.net',
          port: 22, username: 'mfrazier',
        ),
      ]);
      final result = await store.importFromJson(pwaExportFixture);
      expect(result.added, 1, reason: 'only "Build box" is new');
      expect(result.skipped, 1, reason: 'nas already exists');

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      // Existing profile keeps its original title — import does not clobber.
      final existing = loaded.firstWhere((p) => p.host == 'nas.tail123.ts.net');
      expect(existing.title, 'Old Name');
    });

    test('rejects unknown export version', () async {
      final store = ProfilesStore();
      const future = '''
{ "version": 99, "exportedAt": "x", "profiles": [] }
''';
      final result = await store.importFromJson(future);
      expect(result.added, 0);
      expect(result.errors, hasLength(1));
      expect(result.errors.first, contains('Unsupported export version'));
    });
  });

  group('ProfilesStore.importFromJson — robustness', () {
    test('accepts a bare-array (legacy #419) export shape', () async {
      // The PWA's pre-#501 `exportProfilesJSON()` emits a bare array.
      // Forward-compat: the native client should accept it.
      const legacy = '''
[
  { "title": "X", "host": "x.example", "port": 22, "username": "u",
    "authType": "password" }
]
''';
      final store = ProfilesStore();
      final result = await store.importFromJson(legacy);
      expect(result.added, 1);
      expect(result.errors, isEmpty);
    });

    test('returns errors (no throw) on invalid JSON', () async {
      final store = ProfilesStore();
      final result = await store.importFromJson('not json at all');
      expect(result.added, 0);
      expect(result.errors, hasLength(1));
      expect(result.errors.first.toLowerCase(), contains('json'));
      // Storage untouched.
      expect(await store.load(), isEmpty);
    });

    test('returns errors on wrong shape (object without profiles array)',
        () async {
      final store = ProfilesStore();
      const wrong = '{ "version": 1, "junk": true }';
      final result = await store.importFromJson(wrong);
      expect(result.added, 0);
      expect(result.errors, hasLength(1));
    });

    test('skips entries missing required fields, collects errors', () async {
      final store = ProfilesStore();
      const mixed = '''
{
  "version": 1,
  "profiles": [
    { "title": "no host", "port": 22, "username": "u" },
    { "host": "ok.example", "port": 22, "username": "u", "title": "OK" }
  ]
}
''';
      final result = await store.importFromJson(mixed);
      expect(result.added, 1);
      expect(result.errors, hasLength(1));
      final loaded = await store.load();
      expect(loaded.single.host, 'ok.example');
    });

    test('ignores credentials silently — they are not part of SavedProfile',
        () async {
      // Belt-and-braces: even if the PWA export had credentials, the
      // SavedProfile.fromJson factory would not read them and they would
      // never reach storage.
      final store = ProfilesStore();
      const sneaky = '''
{
  "version": 1,
  "profiles": [
    {
      "title": "Sneaky", "host": "evil.example", "port": 22,
      "username": "u",
      "password": "secret", "privateKey": "PRIVATE", "vaultId": "steal"
    }
  ]
}
''';
      final result = await store.importFromJson(sneaky);
      expect(result.added, 1);
      final loaded = await store.load();
      // Serialize to JSON to inspect that credential keys are absent.
      final stored = loaded.single.toJson();
      expect(stored.containsKey('password'), isFalse);
      expect(stored.containsKey('privateKey'), isFalse);
      expect(stored.containsKey('vaultId'), isFalse);
    });
  });
}
