// #724 — the session-menu theme PICKER persists the chosen palette PER-PROFILE
// via `ProfilesStore.setTheme` (mirrors #679 `setFontFamily` + #640
// `setFontSize`). `SavedProfile.theme` carries the PWA `ThemeName` KEY that
// connect maps back to a palette via `paletteIndexForThemeName`. The picker
// upserts onto the matching profile only and is a NO-OP for an ad-hoc connect.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ProfilesStore.setTheme (#724)', () {
    test('setTheme persists onto the matching profile only', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
        SavedProfile(title: 'B', host: 'b', port: 22, username: 'u2'),
      ]);

      final ok = await store.setTheme('a:22:u1', 'dracula');
      expect(ok, isTrue);

      final loaded = await store.load();
      final a = loaded.firstWhere((p) => p.host == 'a');
      final b = loaded.firstWhere((p) => p.host == 'b');
      expect(a.theme, 'dracula');
      expect(b.theme, isNull, reason: 'profile B must be unaffected');
    });

    test('setTheme is a NO-OP for an unmatched (ad-hoc) identity', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
      ]);

      final ok = await store.setTheme('adhoc:22:nobody', 'dracula');
      expect(
        ok,
        isFalse,
        reason:
            'picking a theme on an ad-hoc session must not materialize a '
            'saved profile',
      );

      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.theme, isNull);
    });

    test('setTheme round-trips through save/load', () async {
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a', port: 22, username: 'u1'),
      ]);
      await store.setTheme('a:22:u1', 'tokyoNight');

      final reloaded = await ProfilesStore().load();
      expect(reloaded.single.theme, 'tokyoNight');
    });
  });
}
