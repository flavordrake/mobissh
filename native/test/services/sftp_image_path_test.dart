// Unit tests for the markdown-image SFTP path resolver (#946).
//
// A relative `![](src)` resolves against the .md's directory; an absolute path
// passes through normalized; `http(s)`/`data:`/protocol-relative refs are NOT
// SFTP targets (return null → handled by the network/placeholder path).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/sftp_image_fetcher.dart';

void main() {
  group('resolveSftpImagePath', () {
    test('relative path resolves against the .md directory', () {
      expect(
        resolveSftpImagePath('/home/me/docs/README.md', 'img/diagram.png'),
        '/home/me/docs/img/diagram.png',
      );
    });

    test('leading ./ relative path resolves against the .md directory', () {
      expect(
        resolveSftpImagePath('/home/me/docs/README.md', './pic.png'),
        '/home/me/docs/pic.png',
      );
    });

    test('../ escapes the .md directory', () {
      expect(
        resolveSftpImagePath('/home/me/docs/README.md', '../assets/a.png'),
        '/home/me/assets/a.png',
      );
    });

    test('absolute remote path passes through normalized', () {
      expect(
        resolveSftpImagePath('/home/me/docs/README.md', '/srv/img/x.png'),
        '/srv/img/x.png',
      );
    });

    test('.md at root resolves a relative sibling at root', () {
      expect(
        resolveSftpImagePath('/README.md', 'logo.png'),
        '/logo.png',
      );
    });

    test('http(s) URLs are not SFTP targets', () {
      expect(
        resolveSftpImagePath('/docs/README.md', 'https://x.test/a.png'),
        isNull,
      );
      expect(
        resolveSftpImagePath('/docs/README.md', 'http://x.test/a.png'),
        isNull,
      );
    });

    test('data: and protocol-relative refs are not SFTP targets', () {
      expect(
        resolveSftpImagePath('/docs/README.md', 'data:image/png;base64,AAAA'),
        isNull,
      );
      expect(
        resolveSftpImagePath('/docs/README.md', '//cdn.test/a.png'),
        isNull,
      );
    });

    test('empty / whitespace src returns null', () {
      expect(resolveSftpImagePath('/docs/README.md', ''), isNull);
      expect(resolveSftpImagePath('/docs/README.md', '   '), isNull);
    });
  });
}
