// #867 — SFTP tilde expansion + friendlier error mapping.
//
// SFTP has no shell, so it does NOT expand `~`. The browser passed a literal
// `~/.claude/...` path to listdir → `No such file (code 2)`. `expandTilde`
// resolves `~` / `~/…` / relative paths against the session home (the realpath
// of the SFTP cwd at open). `friendlySftpListError` maps raw SftpStatusError
// codes to a clean empty-state message instead of dumping the raw error.

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
}
