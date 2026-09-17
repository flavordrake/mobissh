// #867 — SFTP tilde expansion + friendlier error mapping.
//
// SFTP has no shell, so it does NOT expand `~`. The browser passed a literal
// `~/.claude/...` path to listdir → `No such file (code 2)`. `expandTilde`
// resolves `~` / `~/…` / relative paths against the session home (the realpath
// of the SFTP cwd at open). `friendlySftpListError` maps raw SftpStatusError
// codes to a clean empty-state message instead of dumping the raw error.
//
// #1165 backfill: pins `friendlySftpMkdirError` (#1133), `parentRemotePath`
// and `joinRemotePath` edge cases. Test-only — today's behaviour is the truth.

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/sftp_session.dart';

void main() {
  group('#867 expandTilde', () {
    const home = '/home/ra';

    test('`~/rest` expands to home + rest', () {
      expect(expandTilde('~/.claude/x', home), '/home/ra/.claude/x');
    });

    test('the real reported path resolves', () {
      expect(
        expandTilde('~/.claude/projects/-home-ra/memory/', home),
        '/home/ra/.claude/projects/-home-ra/memory/',
      );
    });

    test('bare `~` expands to home', () {
      expect(expandTilde('~', home), '/home/ra');
    });

    test('a non-tilde ABSOLUTE path is unchanged', () {
      expect(expandTilde('/etc/ssh/sshd_config', home), '/etc/ssh/sshd_config');
      expect(expandTilde('/', home), '/');
    });

    test('a RELATIVE path is joined onto home/cwd', () {
      expect(expandTilde('notes.txt', home), '/home/ra/notes.txt');
      expect(expandTilde('dir/sub', home), '/home/ra/dir/sub');
    });

    test('an empty path resolves to home', () {
      expect(expandTilde('', home), home);
    });

    test('`~user/…` is left UNCHANGED (server/realpath resolves it)', () {
      // We cannot cheaply resolve another user's home without /etc/passwd, so
      // we leave it to the server's realpath / the friendly error path rather
      // than guess wrong.
      expect(expandTilde('~bob/file', home), '~bob/file');
      expect(expandTilde('~bob', home), '~bob');
    });

    test('a home with a trailing slash does not double the separator', () {
      expect(expandTilde('~/x', '/home/ra/'), '/home/ra/x');
    });
  });

  group('#867 friendlySftpListError', () {
    test('code 2 (no such file) → "Folder not found: <path>"', () {
      final e = SftpStatusError(2, 'No such file');
      expect(
        friendlySftpListError(e, '/home/ra/.claude/projects'),
        'Folder not found: /home/ra/.claude/projects',
      );
    });

    test('code 3 (permission denied) → "Permission denied: <path>"', () {
      final e = SftpStatusError(3, 'Permission denied');
      expect(
        friendlySftpListError(e, '/root/secret'),
        'Permission denied: /root/secret',
      );
    });

    test('any other SftpStatusError code → generic "Couldn\'t open <path>"', () {
      final e = SftpStatusError(4, 'Failure');
      expect(
        friendlySftpListError(e, '/some/path'),
        "Couldn't open /some/path",
      );
    });

    test('a non-SftpStatusError falls back to a generic message', () {
      final e = Exception('boom');
      expect(
        friendlySftpListError(e, '/some/path'),
        "Couldn't open /some/path",
      );
    });
  });

  group('#1165 friendlySftpMkdirError', () {
    const path = '/home/ra/new-dir';

    test('code 3 (permission denied) → "Permission denied: <path>"', () {
      final e = SftpStatusError(3, 'Permission denied');
      expect(friendlySftpMkdirError(e, path), 'Permission denied: $path');
    });

    test('code 11 (already exists) → "Already exists: <path>"', () {
      final e = SftpStatusError(11, 'File already exists');
      expect(friendlySftpMkdirError(e, path), 'Already exists: $path');
    });

    test('code 2 (no such parent) passes the SERVER message through', () {
      // The server is the authority: its own words, path-qualified.
      final e = SftpStatusError(2, 'No such file');
      expect(friendlySftpMkdirError(e, path), 'No such file: $path');
    });

    test('an unknown code with a message → "<message>: <path>"', () {
      final e = SftpStatusError(4, 'Failure');
      expect(friendlySftpMkdirError(e, path), 'Failure: $path');
    });

    test('an unknown code with an EMPTY message → generic "Couldn\'t create"',
        () {
      final e = SftpStatusError(4, '');
      expect(friendlySftpMkdirError(e, path), "Couldn't create $path");
    });

    test('a TimeoutException → busy-connection line (never the raw error)', () {
      final e = TimeoutException('sftp mkdir', const Duration(seconds: 20));
      final msg = friendlySftpMkdirError(e, path);
      expect(msg, contains("didn't respond"));
      expect(msg, isNot(contains(path)));
    });

    test('a non-SftpStatusError falls back to a generic message', () {
      expect(
        friendlySftpMkdirError(Exception('boom'), path),
        "Couldn't create $path",
      );
    });
  });

  group('#1165 parentRemotePath', () {
    test('the root is its own parent', () {
      expect(parentRemotePath('/'), '/');
    });

    test('an empty path resolves to the root', () {
      expect(parentRemotePath(''), '/');
    });

    test('a single top-level segment goes up to the root', () {
      expect(parentRemotePath('/etc'), '/');
    });

    test('a trailing slash is stripped before computing the parent', () {
      expect(parentRemotePath('/etc/'), '/');
      expect(parentRemotePath('/home/ra/'), '/home');
    });

    test('a nested path returns its immediate parent', () {
      expect(parentRemotePath('/home/ra/.claude'), '/home/ra');
    });

    test('a RELATIVE single segment (no slash) goes to the root', () {
      // No separator to split on → treated as top-level.
      expect(parentRemotePath('notes.txt'), '/');
    });
  });

  group('#1165 joinRemotePath', () {
    test('joining onto the root does not double the slash', () {
      expect(joinRemotePath('/', 'etc'), '/etc');
    });

    test('a parent WITHOUT a trailing slash gets one inserted', () {
      expect(joinRemotePath('/home/ra', 'x'), '/home/ra/x');
    });

    test('a parent WITH a trailing slash keeps a single separator', () {
      expect(joinRemotePath('/home/ra/', 'x'), '/home/ra/x');
    });

    test('a `~` parent is joined literally — expansion is expandTilde\'s job',
        () {
      expect(joinRemotePath('~', 'x'), '~/x');
      expect(joinRemotePath('~/', 'x'), '~/x');
    });

    test('an EMPTY child yields parent + "/" (pins today\'s behaviour)', () {
      expect(joinRemotePath('/home/ra', ''), '/home/ra/');
      expect(joinRemotePath('/', ''), '/');
    });

    test('a double-slash parent is NOT normalised (pins today\'s behaviour)',
        () {
      // Only the join seam is collapsed; existing separators pass through so
      // the server's realpath stays the authority.
      expect(joinRemotePath('/home//ra', 'x'), '/home//ra/x');
      expect(joinRemotePath('/home/ra//', 'x'), '/home/ra//x');
    });
  });
}
