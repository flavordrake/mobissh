// Unit tests for [FavoritesStore] (#632).
//
// Covers:
//   - add / remove / toggle / clear
//   - load/save round-trip persistence (fresh store instance re-reads prefs)
//   - PER-PROFILE ISOLATION: profile A's favorites invisible under profile B;
//     two "sessions" (two store reads) of the SAME profile share the set
//   - corrupt JSON / wrong shape / unknown schema version → empty fallback
//   - schema version lives INSIDE the value JSON (not the key)
//   - path normalization (trailing slash) so /var/log == /var/log/

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/favorites_store.dart';

const String _profA = 'a.example:22:alice';
const String _profB = 'b.example:2222:bob';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('PathFavorite', () {
    test('display prefers label, falls back to path', () {
      expect(const PathFavorite(path: '/var/log').display, '/var/log');
      expect(
        const PathFavorite(path: '/var/log', label: 'Logs').display,
        'Logs',
      );
    });

    test('toJson omits empty/null label', () {
      expect(const PathFavorite(path: '/x').toJson().containsKey('label'),
          isFalse);
      expect(
        const PathFavorite(path: '/x', label: 'L').toJson()['label'],
        'L',
      );
    });

    test('fromJson drops entries without a usable path', () {
      expect(PathFavorite.fromJson(<String, Object?>{}), isNull);
      expect(PathFavorite.fromJson(<String, Object?>{'path': 42}), isNull);
      expect(PathFavorite.fromJson('not a map'), isNull);
      expect(PathFavorite.fromJson(<String, Object?>{'path': '/ok'})?.path,
          '/ok');
    });

    test('equality is by normalized path', () {
      expect(
        const PathFavorite(path: '/a'),
        const PathFavorite(path: '/a', label: 'different label'),
      );
    });
  });

  group('normalizePath', () {
    test('strips trailing slash except root', () {
      expect(normalizePath('/var/log/'), '/var/log');
      expect(normalizePath('/var/log'), '/var/log');
      expect(normalizePath('/'), '/');
      expect(normalizePath('  /etc/  '), '/etc');
    });
  });

  group('FavoritesStore add/remove/toggle', () {
    test('add then favoritesFor returns the path', () async {
      final store = FavoritesStore();
      await store.add(_profA, '/var/log');
      final favs = await store.favoritesFor(_profA);
      expect(favs.map((f) => f.path), ['/var/log']);
      expect(await store.isFavorite(_profA, '/var/log'), isTrue);
    });

    test('add is idempotent (no duplicates)', () async {
      final store = FavoritesStore();
      await store.add(_profA, '/var/log');
      await store.add(_profA, '/var/log/'); // normalizes to same
      expect((await store.favoritesFor(_profA)).length, 1);
    });

    test('remove deletes the path', () async {
      final store = FavoritesStore();
      await store.add(_profA, '/var/log');
      await store.remove(_profA, '/var/log');
      expect(await store.isFavorite(_profA, '/var/log'), isFalse);
      expect(await store.favoritesFor(_profA), isEmpty);
    });

    test('toggle flips state and returns the new state', () async {
      final store = FavoritesStore();
      expect(await store.toggle(_profA, '/etc'), isTrue);
      expect(await store.isFavorite(_profA, '/etc'), isTrue);
      expect(await store.toggle(_profA, '/etc'), isFalse);
      expect(await store.isFavorite(_profA, '/etc'), isFalse);
    });

    test('clear empties only the target profile', () async {
      final store = FavoritesStore();
      await store.add(_profA, '/var/log');
      await store.add(_profA, '/etc');
      await store.add(_profB, '/home');
      await store.clear(_profA);
      expect(await store.favoritesFor(_profA), isEmpty);
      expect((await store.favoritesFor(_profB)).map((f) => f.path), ['/home']);
    });

    test('blank path is rejected (no-op)', () async {
      final store = FavoritesStore();
      await store.add(_profA, '   ');
      expect(await store.favoritesFor(_profA), isEmpty);
    });
  });

  group('persistence', () {
    test('survives a fresh store instance (round-trip via prefs)', () async {
      final writer = FavoritesStore();
      await writer.add(_profA, '/var/log', label: 'Logs');
      await writer.add(_profA, '/etc');

      // A brand-new store reading the same mock prefs = "after app restart".
      final reader = FavoritesStore();
      final favs = await reader.favoritesFor(_profA);
      expect(favs.map((f) => f.path), ['/var/log', '/etc']);
      expect(favs.first.label, 'Logs');
    });

    test('schema version is stored INSIDE the value JSON, not the key',
        () async {
      final store = FavoritesStore();
      await store.add(_profA, '/var/log');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(favoritesPrefsKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['version'], 1);
      expect(decoded.containsKey('profiles'), isTrue);
    });
  });

  group('per-profile isolation', () {
    test("profile A's favorites are not visible under profile B", () async {
      final store = FavoritesStore();
      await store.add(_profA, '/var/log');
      expect(await store.isFavorite(_profB, '/var/log'), isFalse);
      expect(await store.favoritesFor(_profB), isEmpty);
    });

    test('two reads of the SAME profile share one set', () async {
      // Simulate two sessions of the same profile: each resolves favorites via
      // the same identity key and sees the same data.
      final session1 = FavoritesStore();
      final session2 = FavoritesStore();
      await session1.add(_profA, '/srv');
      expect(await session2.isFavorite(_profA, '/srv'), isTrue);
      // Un-favoriting in one reflects for the profile (both sessions).
      await session2.remove(_profA, '/srv');
      expect(await session1.isFavorite(_profA, '/srv'), isFalse);
    });
  });

  group('corrupt-data resilience', () {
    test('malformed JSON → empty fallback (no crash)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        favoritesPrefsKey: '{not valid json',
      });
      final store = FavoritesStore();
      expect(await store.load(), isEmpty);
      expect(await store.favoritesFor(_profA), isEmpty);
    });

    test('wrong top-level shape (a list) → empty fallback', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        favoritesPrefsKey: '[1,2,3]',
      });
      final store = FavoritesStore();
      expect(await store.load(), isEmpty);
    });

    test('unknown schema version → empty fallback', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        favoritesPrefsKey: jsonEncode({
          'version': 999,
          'profiles': {
            _profA: [
              {'path': '/var/log'},
            ],
          },
        }),
      });
      final store = FavoritesStore();
      expect(await store.load(), isEmpty);
    });

    test('drops individual corrupt entries but keeps good ones', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        favoritesPrefsKey: jsonEncode({
          'version': 1,
          'profiles': {
            _profA: [
              {'path': '/good'},
              {'nope': true},
              {'path': 123},
              {'path': '/good2', 'label': 'two'},
            ],
          },
        }),
      });
      final store = FavoritesStore();
      final favs = await store.favoritesFor(_profA);
      expect(favs.map((f) => f.path), ['/good', '/good2']);
    });
  });
}
