// #891 — SSH profile default path (file-browser starting directory).
//
// A new OPTIONAL `defaultPath` on the profile model + the browser initial-path
// resolution helper. Covers:
//   - toJson omits an empty defaultPath (no key bump; absent field = migration)
//   - toJson includes a non-empty defaultPath
//   - round-trip through the store preserves defaultPath
//   - OLD profile JSON WITHOUT the field migrates to '' (no crash)
//   - a non-String stored value coerces to '' (corrupt-resilience)
//   - copyWith carries / overrides defaultPath
//   - resolveBrowserInitialPath: empty -> '~' (home); `~`/relative/absolute
//     pass through; surrounding whitespace trimmed

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/file_browser_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SavedProfile.defaultPath (#891)', () {
    test('defaults to empty string', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      expect(p.defaultPath, '');
    });

    test('toJson omits an empty defaultPath', () {
      final p = SavedProfile(title: 't', host: 'h', port: 22, username: 'u');
      expect(p.toJson().containsKey('defaultPath'), isFalse);
    });

    test('toJson includes a non-empty defaultPath', () {
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        defaultPath: '/files',
      );
      expect(p.toJson()['defaultPath'], '/files');
    });

    test('fromJson reads a stored defaultPath', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'title': 't',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'defaultPath': '~/downloads',
      });
      expect(p.defaultPath, '~/downloads');
    });

    test('OLD profile JSON without defaultPath migrates to "" (no crash)', () {
      // A pre-#891 profile blob: no defaultPath key at all.
      final p = SavedProfile.fromJson(<String, dynamic>{
        'title': 'legacy',
        'host': 'old.host',
        'port': 2222,
        'username': 'u',
        'theme': 'nord',
      });
      expect(p.defaultPath, '');
    });

    test('a non-String stored defaultPath coerces to ""', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'title': 't',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'defaultPath': 42,
      });
      expect(p.defaultPath, '');
    });

    test('fromJson trims surrounding whitespace on defaultPath', () {
      final p = SavedProfile.fromJson(<String, dynamic>{
        'title': 't',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'defaultPath': '  /files  ',
      });
      expect(p.defaultPath, '/files');
    });

    test('copyWith carries defaultPath through unchanged', () {
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        defaultPath: '/files',
      );
      expect(p.copyWith(theme: 'nord').defaultPath, '/files');
    });

    test('copyWith overrides defaultPath when supplied', () {
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        defaultPath: '/files',
      );
      expect(p.copyWith(defaultPath: '/other').defaultPath, '/other');
    });
  });

  group('ProfilesStore round-trip (#891)', () {
    test('save -> load preserves a non-empty defaultPath', () async {
      final store = ProfilesStore();
      final p = SavedProfile(
        title: 'whatbox',
        host: 'box.example',
        port: 22,
        username: 'me',
        defaultPath: '/files',
      );
      await store.save(<SavedProfile>[p]);

      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.defaultPath, '/files');
    });

    test('save -> load yields "" for a profile saved without defaultPath',
        () async {
      final store = ProfilesStore();
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
      );
      await store.save(<SavedProfile>[p]);

      final loaded = await store.load();
      expect(loaded.single.defaultPath, '');
    });

    test('upsert preserves defaultPath across an in-place update', () async {
      final store = ProfilesStore();
      final p = SavedProfile(
        title: 't',
        host: 'h',
        port: 22,
        username: 'u',
        defaultPath: '/files',
      );
      await store.upsert(p);
      // Re-save with the same identity but a new default path.
      await store.upsert(p.copyWith(defaultPath: '/data'));

      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.defaultPath, '/data');
    });
  });

  group('resolveBrowserInitialPath (#891)', () {
    test('an empty defaultPath resolves to "~" (SFTP home)', () {
      expect(resolveBrowserInitialPath(''), '~');
    });

    test('a whitespace-only defaultPath resolves to "~"', () {
      expect(resolveBrowserInitialPath('   '), '~');
    });

    test('an absolute defaultPath passes through', () {
      expect(resolveBrowserInitialPath('/files'), '/files');
    });

    test('a "~"-prefixed defaultPath passes through', () {
      expect(resolveBrowserInitialPath('~/downloads'), '~/downloads');
    });

    test('a bare "~" passes through', () {
      expect(resolveBrowserInitialPath('~'), '~');
    });

    test('a relative defaultPath passes through', () {
      expect(resolveBrowserInitialPath('downloads'), 'downloads');
    });

    test('surrounding whitespace is trimmed', () {
      expect(resolveBrowserInitialPath('  /files  '), '/files');
    });
  });
}
