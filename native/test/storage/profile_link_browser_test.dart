// #1197 (slice 2 of #1195) — `SavedProfile.linkBrowserPackage`. Spec:
// `docs/link-browser-routing.md` R7/R12, test A9.
//
// PINNED API:
//   SavedProfile({..., String? linkBrowserPackage})
//   SavedProfile.copyWith({..., String? linkBrowserPackage,
//                          bool clearLinkBrowserPackage = false})
//   toJson: `linkBrowserPackage` OMITTED when null, so a legacy profile
//           round-trips byte-identical (no key bump, the absent field IS the
//           migration — .claude/rules/code-style.md).
//   fromJson: anything that is not a non-empty String reads back as null.
//
// R7/D2: the PACKAGE is stored, never the label — labels change with app
// updates and locale.
// R12: an uninstalled browser is NEVER cleared from the profile. The fallback
// is runtime behaviour, not a config edit.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

Map<String, dynamic> _legacyJson() => <String, dynamic>{
  'title': 'Legacy',
  'host': 'legacy.example',
  'port': 22,
  'username': 'old',
  'theme': 'nord',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('A9 read/coerce (R7)', () {
    test('absent field reads back as null (use the global default)', () {
      expect(SavedProfile.fromJson(_legacyJson()).linkBrowserPackage, isNull);
    });

    test('a package name reads back verbatim', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkBrowserPackage': 'com.work.prisma',
      });
      expect(p.linkBrowserPackage, 'com.work.prisma');
    });

    test('a corrupt (non-string) value reads back as the default', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkBrowserPackage': 42,
      });
      expect(p.linkBrowserPackage, isNull);
    });

    test('an empty-string value reads back as the default', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        ..._legacyJson(),
        'linkBrowserPackage': '',
      });
      expect(p.linkBrowserPackage, isNull);
    });
  });

  group('A9 serialize', () {
    test('null is OMITTED — a legacy profile stays byte-identical', () {
      final p = SavedProfile.fromJson(_legacyJson());
      expect(p.toJson().containsKey('linkBrowserPackage'), isFalse);
    });

    test('a set package is written out', () {
      final p = SavedProfile(
        title: 't',
        host: 'h.example',
        port: 22,
        username: 'u',
        linkBrowserPackage: 'com.work.prisma',
      );
      expect(p.toJson()['linkBrowserPackage'], 'com.work.prisma');
    });
  });

  group('A9 copyWith', () {
    final base = SavedProfile(
      title: 't',
      host: 'h.example',
      port: 22,
      username: 'u',
      linkBrowserPackage: 'com.work.prisma',
    );

    test('carries the field through an unrelated edit', () {
      expect(base.copyWith(title: 'x').linkBrowserPackage, 'com.work.prisma');
    });

    test('sets a new package', () {
      expect(
        base.copyWith(linkBrowserPackage: 'com.android.chrome').linkBrowserPackage,
        'com.android.chrome',
      );
    });

    test('clearLinkBrowserPackage returns to the global default', () {
      expect(base.copyWith(clearLinkBrowserPackage: true).linkBrowserPackage,
          isNull);
    });
  });

  group('A9 round-trip through the store', () {
    test('survives save → load', () async {
      final store = ProfilesStore();
      await store.save([
        SavedProfile(
          title: 'work',
          host: 'work.example',
          port: 22,
          username: 'me',
          linkBrowserPackage: 'com.work.prisma',
        ),
        SavedProfile(
          title: 'home',
          host: 'home.example',
          port: 22,
          username: 'me',
        ),
      ]);
      final loaded = await store.load();
      expect(loaded[0].linkBrowserPackage, 'com.work.prisma');
      expect(loaded[1].linkBrowserPackage, isNull);
    });

    test(
      'R12: a package that is no longer installed is NOT cleared on reload',
      () async {
        final store = ProfilesStore();
        await store.save([
          SavedProfile(
            title: 'work',
            host: 'work.example',
            port: 22,
            username: 'me',
            // Nothing on this device enumerates it — the app may be
            // reinstalled, so the setting stays.
            linkBrowserPackage: 'com.uninstalled.browser',
          ),
        ]);
        final once = await store.load();
        await store.save(once);
        final twice = await store.load();
        expect(twice.single.linkBrowserPackage, 'com.uninstalled.browser');
      },
    );
  });
}
