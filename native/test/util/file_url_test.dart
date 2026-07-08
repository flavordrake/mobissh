// #994 — file:// URLs in terminal output are REMOTE paths on the SSH host.
// Pure conversion layer:
//   * fileUrlToRemotePath: file:// URI -> bare absolute path. Strips the
//     scheme + authority (ls --hyperlink / eza emit the remote HOSTNAME as
//     authority; an empty authority is the common file:///path form),
//     percent-decodes UTF-8, and rejects malformed input with null.
//   * sftpUrlForRemotePath: the canonical sftp://user@host[:port]/path form
//     built from the session identity — :22 omitted (the default port).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/util/file_url.dart';

void main() {
  group('#994 fileUrlToRemotePath', () {
    test('empty authority (file:///path) yields the bare path', () {
      expect(fileUrlToRemotePath('file:///etc/hosts'), '/etc/hosts');
      expect(
        fileUrlToRemotePath('file:///home/dev/workspace/mobissh/notes.md'),
        '/home/dev/workspace/mobissh/notes.md',
      );
    });

    test('hostname authority (ls --hyperlink / eza) is STRIPPED', () {
      expect(fileUrlToRemotePath('file://fd-dev/etc/hosts'), '/etc/hosts');
      expect(
        fileUrlToRemotePath('file://localhost/var/log/syslog'),
        '/var/log/syslog',
      );
    });

    test('percent-encoded spaces decode', () {
      expect(
        fileUrlToRemotePath('file:///home/dev/my%20file.md'),
        '/home/dev/my file.md',
      );
    });

    test('percent-encoded UTF-8 decodes', () {
      expect(
        fileUrlToRemotePath('file:///home/d%C3%A9v/caf%C3%A9.txt'),
        '/home/dév/café.txt',
      );
    });

    test('a plus sign is a literal path char, never a space', () {
      expect(fileUrlToRemotePath('file:///opt/g++/notes'), '/opt/g++/notes');
    });

    test('trailing slash survives (feeds the #999 dir-vs-file rule)', () {
      expect(fileUrlToRemotePath('file:///etc/'), '/etc/');
      expect(fileUrlToRemotePath('file://host/etc/'), '/etc/');
    });

    test('scheme matches case-insensitively', () {
      expect(fileUrlToRemotePath('FILE:///etc/hosts'), '/etc/hosts');
      expect(fileUrlToRemotePath('File:///etc/hosts'), '/etc/hosts');
    });

    test('surrounding whitespace is trimmed', () {
      expect(fileUrlToRemotePath('  file:///etc/hosts  '), '/etc/hosts');
    });

    test('no path at all is malformed -> null', () {
      expect(fileUrlToRemotePath('file://'), isNull);
      expect(fileUrlToRemotePath('file://hostname'), isNull);
    });

    test('malformed percent escapes -> null (rejected, not crashed)', () {
      expect(fileUrlToRemotePath('file:///bad%zzpath'), isNull);
      expect(fileUrlToRemotePath('file:///truncated%2'), isNull);
    });

    test('non-file schemes are not file URLs -> null', () {
      expect(fileUrlToRemotePath('https://example.com/etc'), isNull);
      expect(fileUrlToRemotePath('sftp://u@h/etc'), isNull);
      expect(fileUrlToRemotePath('/etc/hosts'), isNull);
      expect(fileUrlToRemotePath('file:/etc/hosts'), isNull);
      expect(fileUrlToRemotePath(''), isNull);
    });
  });

  group('#994 sftpUrlForRemotePath', () {
    test('default port 22 is omitted', () {
      expect(
        sftpUrlForRemotePath(
          username: 'testuser',
          host: '10.0.0.5',
          port: 22,
          path: '/etc/hosts',
        ),
        'sftp://testuser@10.0.0.5/etc/hosts',
      );
    });

    test('non-default port is included', () {
      expect(
        sftpUrlForRemotePath(
          username: 'testuser',
          host: '127.0.0.1',
          port: 2222,
          path: '/etc/hosts',
        ),
        'sftp://testuser@127.0.0.1:2222/etc/hosts',
      );
    });

    test('a space in the path is percent-encoded (valid URL out)', () {
      expect(
        sftpUrlForRemotePath(
          username: 'dev',
          host: 'fd-dev',
          port: 22,
          path: '/home/dev/my file.md',
        ),
        'sftp://dev@fd-dev/home/dev/my%20file.md',
      );
    });
  });
}
