// #640 — terminal font size persists PER-PROFILE (mirrors #613 per-profile
// theme persistence). `SavedProfile.fontSize` is a persisted profile field in
// `mobissh.profiles.v1`: round-trips through save/load, validates+clamps on
// read (corrupt -> null fallback per .claude/rules config-system policy), and
// survives an import UPSERT. No key bump (version-in-value: the v1 key already
// carries the schema; an absent fontSize is the legacy default).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedProfile.fontSize JSON', () {
    test('toJson omits null fontSize', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      expect(p.toJson().containsKey('fontSize'), isFalse);
    });

    test('toJson includes fontSize when present', () {
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        fontSize: 18,
      );
      expect(p.toJson()['fontSize'], 18);
    });

    test('fromJson reads a numeric fontSize (int or double)', () {
      final pInt = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontSize': 20,
      });
      expect(pInt.fontSize, 20);

      final pDouble = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontSize': 16.5,
      });
      expect(pDouble.fontSize, 16.5);
    });

    test('fromJson clamps an out-of-range fontSize into [8..32]', () {
      final low = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontSize': 2,
      });
      expect(low.fontSize, 8.0);

      final high = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontSize': 999,
      });
      expect(high.fontSize, 32.0);
    });

    test('fromJson tolerates a corrupt fontSize (non-numeric -> null)', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontSize': 'huge',
      });
      expect(p.fontSize, isNull);
    });

    test('fromJson leaves fontSize null when absent (legacy profile)', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
      });
      expect(p.fontSize, isNull);
    });
  });

  group('ProfilesStore round-trip + upsert', () {
    test('save+load round-trips fontSize', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Dev',
          host: 'dev.example',
          port: 22,
          username: 'admin',
          fontSize: 22,
        ),
        SavedProfile(
          title: 'Prod',
          host: 'prod.example',
          port: 2222,
          username: 'deploy',
        ),
      ]);

      final loaded = await store.load();
      expect(loaded, hasLength(2));
      expect(loaded[0].fontSize, 22);
      expect(loaded[1].fontSize, isNull, reason: 'absent -> default (null)');
    });

    test('upsert persists a per-profile fontSize change', () async {
      final store = ProfilesStore();
      final base = SavedProfile(
        title: 'Dev',
        host: 'dev.example',
        port: 22,
        username: 'admin',
      );
      await store.save(<SavedProfile>[base]);

      // Owner steps the font up for THIS profile.
      await store.upsert(
        SavedProfile(
          title: base.title,
          host: base.host,
          port: base.port,
          username: base.username,
          fontSize: 19,
        ),
      );

      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.fontSize, 19);
    });

    test('per-profile isolation: changing A does not touch B', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
        SavedProfile(title: 'B', host: 'b', port: 22, username: 'u2'),
      ]);

      await store.upsert(
        SavedProfile(
          title: 'A',
          host: 'a',
          port: 22,
          username: 'u1',
          fontSize: 24,
        ),
      );

      final loaded = await store.load();
      final a = loaded.firstWhere((p) => p.host == 'a');
      final b = loaded.firstWhere((p) => p.host == 'b');
      expect(a.fontSize, 24);
      expect(b.fontSize, isNull, reason: 'profile B must be unaffected');
    });

    test('import UPSERT preserves fontSize from the incoming entry', () async {
      final store = ProfilesStore();
      // Existing identity-only profile (no fontSize yet).
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'NAS',
          host: 'nas.example',
          port: 22,
          username: 'me',
        ),
      ]);

      final envelope = jsonEncode(<String, dynamic>{
        'version': 1,
        'profiles': <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'NAS',
            'host': 'nas.example',
            'port': 22,
            'username': 'me',
            'fontSize': 17,
          },
        ],
      });
      final result = await store.importFromJson(envelope);
      expect(result.updated, 1);

      final loaded = await store.load();
      expect(
        loaded.single.fontSize,
        17,
        reason: 're-import must refresh the per-profile font size',
      );
    });
  });
}
