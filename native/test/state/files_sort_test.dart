// Unit tests for the file-browser sort comparator + preference store (#951).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/state/files_sort_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

SftpEntry _dir(String name, {int? mtime}) =>
    SftpEntry(name: name, path: '/$name', isDirectory: true, modifyTime: mtime);

SftpEntry _file(String name, {int? size, int? mtime}) => SftpEntry(
  name: name,
  path: '/$name',
  isDirectory: false,
  size: size,
  modifyTime: mtime,
);

List<String> _names(List<SftpEntry> e) => e.map((x) => x.name).toList();

void main() {
  group('sortEntries — directories always pinned first', () {
    final entries = [
      _file('zeta.txt', size: 10, mtime: 100),
      _dir('beta'),
      _file('alpha.md', size: 20, mtime: 200),
      _dir('alpha'),
    ];

    for (final key in FilesSortKey.values) {
      for (final asc in [true, false]) {
        test('dirs first with key=$key ascending=$asc', () {
          final sorted = sortEntries(
            entries,
            FilesSortPref(key: key, ascending: asc),
          );
          // First two are the directories, last two are the files.
          expect(sorted[0].isDirectory, isTrue);
          expect(sorted[1].isDirectory, isTrue);
          expect(sorted[2].isDirectory, isFalse);
          expect(sorted[3].isDirectory, isFalse);
        });
      }
    }
  });

  group('sortEntries — by name', () {
    final entries = [_file('c.txt'), _file('a.txt'), _file('B.txt')];

    test('ascending (case-insensitive)', () {
      final sorted = sortEntries(entries, const FilesSortPref());
      expect(_names(sorted), ['a.txt', 'B.txt', 'c.txt']);
    });

    test('descending', () {
      final sorted = sortEntries(
        entries,
        const FilesSortPref(ascending: false),
      );
      expect(_names(sorted), ['c.txt', 'B.txt', 'a.txt']);
    });
  });

  group('sortEntries — by size', () {
    final entries = [
      _file('big', size: 5000),
      _file('small', size: 10),
      _file('mid', size: 500),
    ];

    test('ascending', () {
      final sorted = sortEntries(
        entries,
        const FilesSortPref(key: FilesSortKey.size),
      );
      expect(_names(sorted), ['small', 'mid', 'big']);
    });

    test('descending', () {
      final sorted = sortEntries(
        entries,
        const FilesSortPref(key: FilesSortKey.size, ascending: false),
      );
      expect(_names(sorted), ['big', 'mid', 'small']);
    });
  });

  group('sortEntries — by modified', () {
    final entries = [
      _file('newest', mtime: 3000),
      _file('oldest', mtime: 1000),
      _file('middle', mtime: 2000),
    ];

    test('ascending (oldest first)', () {
      final sorted = sortEntries(
        entries,
        const FilesSortPref(key: FilesSortKey.modified),
      );
      expect(_names(sorted), ['oldest', 'middle', 'newest']);
    });

    test('descending (newest first)', () {
      final sorted = sortEntries(
        entries,
        const FilesSortPref(key: FilesSortKey.modified, ascending: false),
      );
      expect(_names(sorted), ['newest', 'middle', 'oldest']);
    });
  });

  group('sortEntries — by type (extension)', () {
    final entries = [
      _file('script.sh'),
      _file('notes.md'),
      _file('photo.png'),
    ];

    test('ascending by extension', () {
      final sorted = sortEntries(
        entries,
        const FilesSortPref(key: FilesSortKey.type),
      );
      // md < png < sh
      expect(_names(sorted), ['notes.md', 'photo.png', 'script.sh']);
    });
  });

  group('FilesSortNotifier — persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('default is name ascending', () async {
      final prefs = SharedPreferences.getInstance();
      final n = FilesSortNotifier('h:22:u', prefs: prefs);
      expect(n.state, filesSortDefault);
    });

    test('set key + direction persists and a fresh notifier hydrates it',
        () async {
      final prefs = SharedPreferences.getInstance();
      final n = FilesSortNotifier('h:22:u', prefs: prefs);
      await n.setKey(FilesSortKey.size);
      await n.toggleDirection();
      expect(n.state, const FilesSortPref(key: FilesSortKey.size, ascending: false));

      // Fresh notifier for the same profile reads back the persisted value.
      final n2 = FilesSortNotifier('h:22:u', prefs: prefs);
      await Future<void>.delayed(Duration.zero); // let _hydrate run
      expect(n2.state, const FilesSortPref(key: FilesSortKey.size, ascending: false));
    });

    test('per-profile isolation: profile B keeps the default', () async {
      final prefs = SharedPreferences.getInstance();
      final a = FilesSortNotifier('a:22:u', prefs: prefs);
      await a.setKey(FilesSortKey.modified);

      final b = FilesSortNotifier('b:22:u', prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(b.state, filesSortDefault);
    });
  });
}
