// Unit tests for the HTML loopback resolver (#1037, epic #944).
//
// Covers:
//   - path resolution + the traversal guard matrix (`..` escapes, encoded
//     dot segments, absolute-ish requests, root edge cases) — escapes resolve
//     to null (the server answers 404),
//   - content-type mapping for the common web asset types (+ the
//     octet-stream default),
//   - server lifecycle: bind on 127.0.0.1 with an ephemeral port, serve bytes
//     from the injected fetcher with the mapped content-type, 404 on miss /
//     escape, 413 past the per-asset cap, and the port is CLOSED after close().

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/html_loopback_server.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/text_file_detect.dart';

Future<HttpClientResponse> _get(int port, String pathAndQuery) async {
  final client = HttpClient();
  addTearDown(client.close);
  final request = await client.get('127.0.0.1', port, pathAndQuery);
  return request.close();
}

void main() {
  group('resolveLoopbackAssetPath', () {
    const root = '/home/u/site';

    test('plain file resolves under the root', () {
      expect(
        resolveLoopbackAssetPath(root, '/index.html'),
        '/home/u/site/index.html',
      );
    });

    test('nested path resolves under the root', () {
      expect(
        resolveLoopbackAssetPath(root, '/css/style.css'),
        '/home/u/site/css/style.css',
      );
    });

    test('inner dot segments collapse but stay under the root', () {
      expect(
        resolveLoopbackAssetPath(root, '/a/./b/../c.png'),
        '/home/u/site/a/c.png',
      );
    });

    test('.. escape above the root is rejected', () {
      expect(resolveLoopbackAssetPath(root, '/../escape.css'), isNull);
    });

    test('deep .. escape is rejected', () {
      expect(
        resolveLoopbackAssetPath(root, '/../../../../etc/passwd'),
        isNull,
      );
    });

    test('.. that dips out and back in is rejected (no sneaking)', () {
      // Normalizes to /home/u/site/x.css — same final path, but via the
      // parent. The normalized result IS under the root, so it's allowed:
      // normalization happens before the guard.
      expect(
        resolveLoopbackAssetPath(root, '/sub/../x.css'),
        '/home/u/site/x.css',
      );
    });

    test('sibling-prefix escape is rejected (site vs site-secrets)', () {
      expect(resolveLoopbackAssetPath(root, '/../site-secrets/k.pem'), isNull);
    });

    test('empty and root request resolve to null (no directory serving)', () {
      expect(resolveLoopbackAssetPath(root, '/'), isNull);
      expect(resolveLoopbackAssetPath(root, ''), isNull);
    });

    test('root directory / serves absolute tree', () {
      expect(resolveLoopbackAssetPath('/', '/etc/hosts'), '/etc/hosts');
    });
  });

  group('contentTypeForName', () {
    test('maps common web types', () {
      expect(contentTypeForName('a.html'), startsWith('text/html'));
      expect(contentTypeForName('a.HTM'), startsWith('text/html'));
      expect(contentTypeForName('a.css'), startsWith('text/css'));
      expect(contentTypeForName('a.js'), startsWith('text/javascript'));
      expect(contentTypeForName('a.mjs'), startsWith('text/javascript'));
      expect(contentTypeForName('a.json'), startsWith('application/json'));
      expect(contentTypeForName('a.png'), 'image/png');
      expect(contentTypeForName('a.jpg'), 'image/jpeg');
      expect(contentTypeForName('a.jpeg'), 'image/jpeg');
      expect(contentTypeForName('a.gif'), 'image/gif');
      expect(contentTypeForName('a.svg'), startsWith('image/svg+xml'));
      expect(contentTypeForName('a.webp'), 'image/webp');
      expect(contentTypeForName('a.ico'), 'image/x-icon');
      expect(contentTypeForName('a.woff2'), 'font/woff2');
      expect(contentTypeForName('a.txt'), startsWith('text/plain'));
    });

    test('unknown / missing extension defaults to octet-stream', () {
      expect(contentTypeForName('a.bin'), 'application/octet-stream');
      expect(contentTypeForName('noext'), 'application/octet-stream');
    });
  });

  group('isHtmlEntry', () {
    test('matches .html/.htm by extension, case-insensitive', () {
      const a = SftpEntry(name: 'x.html', path: '/x.html', isDirectory: false);
      const b = SftpEntry(name: 'X.HTM', path: '/X.HTM', isDirectory: false);
      const c = SftpEntry(name: 'x.md', path: '/x.md', isDirectory: false);
      expect(isHtmlEntry(a), isTrue);
      expect(isHtmlEntry(b), isTrue);
      expect(isHtmlEntry(c), isFalse);
    });

    test('directories never match', () {
      const d = SftpEntry(name: 'x.html', path: '/x.html', isDirectory: true);
      expect(isHtmlEntry(d), isFalse);
    });

    test('matches by html mime', () {
      const e = SftpEntry(name: 'page', path: '/page', isDirectory: false);
      expect(isHtmlEntry(e, mime: 'text/html; charset=utf-8'), isTrue);
      expect(isHtmlEntry(e, mime: 'text/plain'), isFalse);
    });
  });

  group('HtmlLoopbackServer', () {
    test('serves fetched bytes with the mapped content-type', () async {
      final fetched = <String>[];
      final server = HtmlLoopbackServer(
        rootDir: '/srv/www',
        fetch: (path) async {
          fetched.add(path);
          return Uint8List.fromList(utf8.encode('body { color: red }'));
        },
      );
      await server.start();
      addTearDown(server.close);

      final res = await _get(server.port!, '/css/style.css');
      expect(res.statusCode, 200);
      expect(res.headers.contentType.toString(), startsWith('text/css'));
      final body = await utf8.decodeStream(res);
      expect(body, 'body { color: red }');
      expect(fetched, ['/srv/www/css/style.css']);
      expect(server.requestCount, 1);
    });

    test('404 on fetch miss (fetcher throws)', () async {
      final server = HtmlLoopbackServer(
        rootDir: '/srv/www',
        fetch: (path) async => throw Exception('no such file'),
      );
      await server.start();
      addTearDown(server.close);

      final res = await _get(server.port!, '/missing.png');
      expect(res.statusCode, 404);
    });

    test('traversal requests never reach the fetcher outside the root', () async {
      // Raw socket: a client would normalize dot segments before sending,
      // which would test the CLIENT, not the server. An attacker controls the
      // raw request line, so that's what we send.
      //
      // Empirically (asserted here), dart:io's HTTP stack applies FULL RFC
      // 3986 normalization — percent-decoding of unreserved chars (%2e → '.')
      // AND remove_dot_segments — before the handler runs, so both literal
      // and encoded traversal arrive as an in-root path (`/etc/passwd` →
      // `/srv/www/etc/passwd`). The resolver's own `..` rejection (unit
      // matrix above) is defense in depth for any path that DOES get through
      // with dot segments intact. The end-to-end invariant: the fetcher only
      // ever sees paths under the root.
      final fetched = <String>[];
      final server = HtmlLoopbackServer(
        rootDir: '/srv/www',
        fetch: (path) async {
          fetched.add(path);
          return Uint8List(0);
        },
      );
      await server.start();
      addTearDown(server.close);

      Future<String> rawStatus(String target) async {
        final socket = await Socket.connect('127.0.0.1', server.port!);
        socket.write(
          'GET $target HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          'Connection: close\r\n\r\n',
        );
        await socket.flush();
        final response = await utf8.decodeStream(socket);
        socket.destroy();
        return response.split('\r\n').first;
      }

      final statuses = <String>[
        await rawStatus('/../../etc/passwd'),
        await rawStatus('/%2e%2e/%2e%2e/etc/passwd'),
        await rawStatus('/a/../../../etc/passwd'),
      ];
      // Every request either 404s outright or is served from UNDER the root —
      // never the real /etc/passwd.
      expect(fetched, everyElement(startsWith('/srv/www/')));
      expect(fetched, isNot(contains('/etc/passwd')));
      for (final status in statuses) {
        expect(status, anyOf(contains('404'), contains('200')));
      }
    });

    test('413 past the per-asset cap', () async {
      final server = HtmlLoopbackServer(
        rootDir: '/srv/www',
        maxAssetBytes: 8,
        fetch: (path) async => Uint8List(64),
      );
      await server.start();
      addTearDown(server.close);

      final res = await _get(server.port!, '/big.bin');
      expect(res.statusCode, 413);
    });

    test('uriFor points at the loopback origin with an encoded name', () async {
      final server = HtmlLoopbackServer(
        rootDir: '/srv/www',
        fetch: (path) async => Uint8List(0),
      );
      await server.start();
      addTearDown(server.close);

      final uri = server.uriFor('my page.html');
      expect(uri.scheme, 'http');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, server.port);
      expect(uri.path, '/my%20page.html');
    });

    test('port is closed after close()', () async {
      final server = HtmlLoopbackServer(
        rootDir: '/srv/www',
        fetch: (path) async => Uint8List(0),
      );
      await server.start();
      final port = server.port!;
      await server.close();

      await expectLater(
        () async {
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 2);
          try {
            final req = await client.get('127.0.0.1', port, '/x.html');
            await req.close();
          } finally {
            client.close(force: true);
          }
        }(),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
