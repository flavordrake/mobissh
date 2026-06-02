// #679 — terminal font FAMILY persists PER-PROFILE (mirrors #640 per-profile
// font size + #613 per-profile theme). `SavedProfile.fontFamily` is a persisted
// profile field in `mobissh.profiles.v1`: round-trips through save/load,
// validates against the bundled families on read (unknown -> null fallback per
// .claude/rules config-system policy), and survives an import UPSERT. No key
// bump (version-in-value: the v1 key already carries the schema; an absent
// fontFamily is the legacy default).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedProfile.fontFamily JSON', () {
    test('toJson omits null fontFamily', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      expect(p.toJson().containsKey('fontFamily'), isFalse);
    });

    test('toJson includes fontFamily when present', () {
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        fontFamily: 'FiraCode',
      );
      expect(p.toJson()['fontFamily'], 'FiraCode');
    });

    test('fromJson reads a known bundled family', () {
      for (final fam in ['JetBrainsMono', 'FiraCode', 'CascadiaCode']) {
        final p = SavedProfile.fromJson(<String, dynamic>{
          'host': 'h',
          'username': 'u',
          'fontFamily': fam,
        });
        expect(p.fontFamily, fam);
      }
    });

    test('fromJson tolerates an unknown family (-> null fallback)', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontFamily': 'ComicSansMono',
      });
      expect(
        p.fontFamily,
        isNull,
        reason:
            'a stale/typo family must not survive read — session falls '
            'back to the default face',
      );
    });

    test('fromJson tolerates a non-string family (-> null)', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'fontFamily': 42,
      });
      expect(p.fontFamily, isNull);
    });

    test('fromJson leaves fontFamily null when absent (legacy profile)', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'host': 'h',
        'username': 'u',
      });
      expect(p.fontFamily, isNull);
    });
  });

  group('ProfilesStore round-trip + upsert', () {
    test('save+load round-trips fontFamily', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Dev',
          host: 'dev.example',
          port: 22,
          username: 'admin',
          fontFamily: 'CascadiaCode',
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
      expect(loaded[0].fontFamily, 'CascadiaCode');
      expect(loaded[1].fontFamily, isNull, reason: 'absent -> default (null)');
    });

    test('setFontFamily persists onto the matching profile only', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
        SavedProfile(title: 'B', host: 'b', port: 22, username: 'u2'),
      ]);

      final ok = await store.setFontFamily('a:22:u1', 'FiraCode');
      expect(ok, isTrue);

      final loaded = await store.load();
      final a = loaded.firstWhere((p) => p.host == 'a');
      final b = loaded.firstWhere((p) => p.host == 'b');
      expect(a.fontFamily, 'FiraCode');
      expect(b.fontFamily, isNull, reason: 'profile B must be unaffected');
    });

    test(
      'setFontFamily is a NO-OP for an unmatched (ad-hoc) identity',
      () async {
        final store = ProfilesStore();
        await store.save(<SavedProfile>[
          SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
        ]);

        final ok = await store.setFontFamily('adhoc:22:nobody', 'FiraCode');
        expect(
          ok,
          isFalse,
          reason:
              'picking a font on an ad-hoc session must not materialize a '
              'saved profile',
        );

        final loaded = await store.load();
        expect(loaded, hasLength(1));
        expect(loaded.single.fontFamily, isNull);
      },
    );

    test(
      'import UPSERT preserves fontFamily from the incoming entry',
      () async {
        final store = ProfilesStore();
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
              'fontFamily': 'FiraCode',
            },
          ],
        });
        final result = await store.importFromJson(envelope);
        expect(result.updated, 1);

        final loaded = await store.load();
        expect(
          loaded.single.fontFamily,
          'FiraCode',
          reason: 're-import must refresh the per-profile font family',
        );
      },
    );
  });
}
