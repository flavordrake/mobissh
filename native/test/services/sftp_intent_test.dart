// #1279 S1 — `sftp://` link parser + `mobissh://sftp` verb (docs/deep-link-intents.md §15, F1/F2/F6).
//
// Pure Dart. Accept table, reject table (each with its reason), and a seeded
// mutation fuzz of the accept table that must never throw and whose every
// accepted path must hold the F6 invariants and round-trip through #994's
// `sftpUrlForRemotePath`.
//
// API pinned (lib/services/sftp_intent.dart):
//   ConnectIntentResult parseSftpUri(String link);
//   ConnectIntentResult parseLink(String link);   // dispatch on scheme
//   String? validateLinkPath(String decoded);     // normalised path or null
//   ConnectVerb.sftp, ConnectRequest.path,
//   ConnectIntentReason.{credentialInLink, badPath, tooLong}

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/services/sftp_intent.dart';
import 'package:mobissh/util/file_url.dart';

ConnectRequest ok(String link) {
  final r = parseLink(link);
  expect(r, isA<ConnectIntentParsed>(), reason: 'expected accept: $link');
  return (r as ConnectIntentParsed).request;
}

void rejects(String link, ConnectIntentReason reason, {String? key}) {
  final r = parseLink(link);
  expect(r, isA<ConnectIntentRejected>(), reason: 'expected reject: $link');
  final rej = r as ConnectIntentRejected;
  expect(rej.reason, reason, reason: 'reason for: $link');
  if (key != null) expect(rej.key, key, reason: 'key for: $link');
}

String _seg(int n) => 'a' * n;

void main() {
  group('F6 accept table', () {
    test('sftp://h — no path, default port, no user', () {
      final r = ok('sftp://h');
      expect(r.verb, ConnectVerb.sftp);
      expect(r.host, 'h');
      expect(r.port, 22);
      expect(r.user, isNull);
      expect(r.path, isNull);
    });

    test('sftp://h/ — root', () {
      expect(ok('sftp://h/').path, '/');
    });

    test('sftp://u@h:2222/a/b — user, port, absolute path', () {
      final r = ok('sftp://u@h:2222/a/b');
      expect(r.user, 'u');
      expect(r.port, 2222);
      expect(r.path, '/a/b');
    });

    test('sftp://u@h/~ — home', () {
      expect(ok('sftp://u@h/~').path, '~');
    });

    test('sftp://u@h/~/x y — home-relative, raw space kept', () {
      expect(ok('sftp://u@h/~/x y').path, '~/x y');
    });

    test('sftp://u@h/~/x%20y — encoded space decoded once', () {
      expect(ok('sftp://u@h/~/x%20y').path, '~/x y');
    });

    test('sftp://u@[::1]/x — bracketed IPv6, stored without brackets', () {
      final r = ok('sftp://u@[::1]/x');
      expect(r.host, '::1');
      expect(r.path, '/x');
    });

    test('sftp://u@[::1]:2200/x — bracketed IPv6 with a port', () {
      final r = ok('sftp://u@[::1]:2200/x');
      expect(r.host, '::1');
      expect(r.port, 2200);
    });

    test('F1: ;fingerprint= is parsed and ignored', () {
      final r = ok('sftp://u;fingerprint=ssh-ed25519-ab-cd@h/x');
      expect(r.user, 'u');
      expect(r.host, 'h');
      expect(r.path, '/x');
    });

    test('unknown c-params are ignored (R7)', () {
      expect(ok('sftp://u;foo=bar,fingerprint=ab@h/x').user, 'u');
    });

    test('scheme and host are case-insensitive', () {
      final r = ok('SFTP://H/x');
      expect(r.host, 'h');
      expect(r.path, '/x');
    });

    test('; in the path is literal (round-trips #994 output)', () {
      expect(ok('sftp://h/a;b').path, '/a;b');
    });

    test('D5: ;type= is not interpreted', () {
      expect(ok('sftp://h/a.txt;type=a').path, '/a.txt;type=a');
    });

    test('%252e decodes once to a literal name %2e', () {
      expect(ok('sftp://h/%252e').path, '/%2e');
    });

    test('one trailing slash is kept as a directory hint (#999)', () {
      expect(ok('sftp://h/a/b/').path, '/a/b/');
    });

    test('a ~ segment that is not first is a literal name', () {
      expect(ok('sftp://h/a/~').path, '/a/~');
    });

    test('multi-byte UTF-8 segment decodes', () {
      expect(ok('sftp://h/caf%C3%A9').path, '/café');
    });

    test('segment of 255 bytes, 64 segments and a 4096-byte path accepted', () {
      expect(ok('sftp://h/${_seg(255)}').path, '/${_seg(255)}');
      final deep = List.filled(64, 'a').join('/');
      expect(ok('sftp://h/$deep').path, '/$deep');
      final big = List.filled(16, _seg(255)).join('/');
      expect(utf8.encode('/$big').length, 4096);
      expect(ok('sftp://h/$big').path, '/$big');
    });

    test('mobissh://sftp?host=h&path=%2Fa%2Fb', () {
      final r = ok('mobissh://sftp?host=h&path=%2Fa%2Fb');
      expect(r.verb, ConnectVerb.sftp);
      expect(r.host, 'h');
      expect(r.path, '/a/b');
    });

    test('mobissh://sftp?name=al&path=~', () {
      final r = ok('mobissh://sftp?name=al&path=~');
      expect(r.name, 'al');
      expect(r.host, isNull);
      expect(r.path, '~');
    });

    test('mobissh://sftp?host=h&port=2222&user=u&path=~/linkdir', () {
      final r = ok('mobissh://sftp?host=h&port=2222&user=u&path=~/linkdir');
      expect(r.port, 2222);
      expect(r.user, 'u');
      expect(r.path, '~/linkdir');
    });

    test('mobissh://sftp without path opens at the default (null)', () {
      expect(ok('mobissh://sftp?host=h').path, isNull);
    });

    test('mobissh://sftp path %252F stays a literal %2F name', () {
      expect(ok('mobissh://sftp?host=h&path=/a%252Fb').path, '/a%2Fb');
    });

    test('parseLink still routes plain mobissh:// links', () {
      final r = ok('mobissh://connect?host=h');
      expect(r.verb, ConnectVerb.connect);
      expect(r.path, isNull);
    });
  });

  group('F2: a credential in the link rejects the whole link', () {
    test('u:pw@', () {
      rejects('sftp://u:pw@h/', ConnectIntentReason.credentialInLink);
    });
    test('u:@', () {
      rejects('sftp://u:@h/', ConnectIntentReason.credentialInLink);
    });
    test(':pw@ with no user', () {
      rejects('sftp://:pw@h/', ConnectIntentReason.credentialInLink);
    });
    test('percent-encoded colon', () {
      rejects('sftp://u%3Apw@h/', ConnectIntentReason.credentialInLink);
    });
    test('colon among c-params', () {
      rejects('sftp://u;fingerprint=a:b@h/',
          ConnectIntentReason.credentialInLink);
    });
  });

  group('F6 reject table — authority', () {
    test('two @', () {
      rejects('sftp://a@b@h/', ConnectIntentReason.malformed);
    });
    test('empty userinfo', () {
      rejects('sftp://@h/', ConnectIntentReason.badParam, key: 'user');
    });
    test('user failing R4', () {
      rejects('sftp://a%20b@h/', ConnectIntentReason.badParam, key: 'user');
    });
    for (final bad in ['h:', 'h:0', 'h:65536', 'h:22a', 'h:-1']) {
      test('port $bad', () {
        rejects('sftp://$bad/', ConnectIntentReason.badParam, key: 'port');
      });
    }
    test('IPv6 zone id', () {
      rejects('sftp://[fe80::1%25eth0]/', ConnectIntentReason.badParam,
          key: 'host');
    });
    test('unicode host', () {
      rejects('sftp://hôst/', ConnectIntentReason.badParam, key: 'host');
    });
    test('encoded unicode host', () {
      rejects('sftp://h%C3%B4st/', ConnectIntentReason.badParam, key: 'host');
    });
    test('empty host', () {
      rejects('sftp:///x', ConnectIntentReason.badParam, key: 'host');
      rejects('sftp://', ConnectIntentReason.badParam, key: 'host');
      rejects('sftp://u@', ConnectIntentReason.badParam, key: 'host');
    });
    test('unbracketed IPv6', () {
      rejects('sftp://::1/x', ConnectIntentReason.badParam);
    });
    test('junk after a bracketed host', () {
      rejects('sftp://[::1]x/', ConnectIntentReason.badParam, key: 'host');
    });
    test('duplicate c-param', () {
      rejects('sftp://u;fingerprint=a,fingerprint=b@h/',
          ConnectIntentReason.duplicateKey,
          key: 'fingerprint');
    });
    test('fingerprint outside its shape', () {
      rejects('sftp://u;fingerprint=a+b@h/', ConnectIntentReason.badParam,
          key: 'fingerprint');
      rejects('sftp://u;fingerprint=@h/', ConnectIntentReason.badParam,
          key: 'fingerprint');
      rejects('sftp://u;fingerprint=${'a' * 257}@h/',
          ConnectIntentReason.badParam,
          key: 'fingerprint');
    });
    test('c-param without a value', () {
      rejects('sftp://u;fingerprint@h/', ConnectIntentReason.malformed);
    });
    test('query or fragment', () {
      rejects('sftp://h/?q', ConnectIntentReason.malformed);
      rejects('sftp://h/x#f', ConnectIntentReason.malformed);
      rejects('sftp://h?q', ConnectIntentReason.malformed);
    });
    test('bad escape in the authority', () {
      rejects('sftp://u%zz@h/', ConnectIntentReason.malformed);
    });
  });

  group('F6 reject table — path', () {
    for (final bad in <String>[
      '/a/../b',
      '/a/%2e%2e/b',
      '/a/%2E%2E/b',
      '/./a',
      '/a/.',
      '/..',
      '//a',
      '/a//b',
      '/a//',
      '/a%2Fb',
      '/a%2fb',
      '/a%00',
      '/a%0a',
      '/a%7f',
      '/a%1b',
      '/~root/',
      '/~root',
      '/a%zz',
      '/a%',
      '/a%4',
      '/a%C0%AF',
      '/a%FF',
      '/a%E2%82',
    ]) {
      test(bad, () {
        rejects('sftp://h$bad', ConnectIntentReason.badPath);
      });
    }

    test('segment of 256 bytes', () {
      rejects('sftp://h/${_seg(256)}', ConnectIntentReason.badPath);
    });

    test('multi-byte segment over 255 bytes', () {
      // 128 × é = 256 bytes in 128 characters.
      rejects('sftp://h/${'%C3%A9' * 128}', ConnectIntentReason.badPath);
    });

    test('path of 4097 bytes', () {
      final big = List.filled(16, _seg(255)).join('/');
      rejects('sftp://h/$big/', ConnectIntentReason.badPath);
    });

    test('65 segments', () {
      rejects('sftp://h/${List.filled(65, 'a').join('/')}',
          ConnectIntentReason.badPath);
    });
  });

  group('whole-link limits', () {
    test('link of 8193 bytes is tooLong', () {
      final link = 'sftp://h/${'a' * (8193 - 9)}';
      expect(link.length, 8193);
      rejects(link, ConnectIntentReason.tooLong);
    });
    test('mobissh link of 8193 bytes is tooLong', () {
      final link = 'mobissh://connect?host=h&x=${'a' * (8193 - 27)}';
      expect(link.length, 8193);
      rejects(link, ConnectIntentReason.tooLong);
    });
    test('leading or trailing whitespace', () {
      rejects(' sftp://h/', ConnectIntentReason.malformed);
      rejects('sftp://h/ ', ConnectIntentReason.malformed);
    });
    test('raw control characters', () {
      rejects('sftp://h/a\nb', ConnectIntentReason.malformed);
      rejects('sftp://h/a\u0000', ConnectIntentReason.malformed);
      rejects('sftp://h/a\u007f', ConnectIntentReason.malformed);
    });
    test('other schemes', () {
      rejects('ssh://h/', ConnectIntentReason.malformed);
      rejects('sftp:/h', ConnectIntentReason.malformed);
      rejects('file:///etc', ConnectIntentReason.malformed);
      rejects('', ConnectIntentReason.malformed);
    });
  });

  group('mobissh://sftp grammar and G3', () {
    test('G3: path on connect rejects the whole link', () {
      rejects('mobissh://connect?host=h&path=/x', ConnectIntentReason.badParam,
          key: 'path');
    });
    test('G3: path on create rejects the whole link', () {
      rejects('mobissh://create?host=h&path=/x', ConnectIntentReason.badParam,
          key: 'path');
    });
    test('tmux on sftp', () {
      rejects('mobissh://sftp?host=h&tmux=s', ConnectIntentReason.badParam,
          key: 'tmux');
    });
    test('window on sftp', () {
      rejects('mobissh://sftp?host=h&window=w', ConnectIntentReason.badParam,
          key: 'window');
    });
    test('relative path', () {
      rejects('mobissh://sftp?host=h&path=rel', ConnectIntentReason.badPath);
    });
    test('empty path', () {
      rejects('mobissh://sftp?host=h&path=', ConnectIntentReason.badPath);
    });
    test('dot segments, ~user, NUL in path', () {
      rejects('mobissh://sftp?host=h&path=/a/../b',
          ConnectIntentReason.badPath);
      rejects('mobissh://sftp?host=h&path=~root',
          ConnectIntentReason.badPath);
      rejects('mobissh://sftp?host=h&path=/a%00',
          ConnectIntentReason.malformed);
    });
    test('sftp without host or name is malformed', () {
      rejects('mobissh://sftp?path=/x', ConnectIntentReason.malformed);
      rejects('mobissh://sftp', ConnectIntentReason.malformed);
    });
    test('claude= still reserved on sftp', () {
      rejects('mobissh://sftp?host=h&claude=x', ConnectIntentReason.reserved,
          key: 'claude');
    });
    test('sftp?name= matches through the alias like connect', () {
      final p = ok('mobissh://sftp?name=al&path=/x');
      final match = matchConnectRequest(p, [], alias: (_) => null);
      expect(match, isA<AliasMiss>());
    });
  });

  group('validateLinkPath', () {
    test('accepts and normalises', () {
      expect(validateLinkPath('/'), '/');
      expect(validateLinkPath('~'), '~');
      expect(validateLinkPath('~/'), '~/');
      expect(validateLinkPath('~/a/b/'), '~/a/b/');
      expect(validateLinkPath('/a;b'), '/a;b');
    });
    test('rejects', () {
      for (final bad in [
        '',
        'a',
        '~u',
        '/a/./b',
        '/a/..',
        '//',
        '/a\u0000',
        '/a\u001f',
        '/a\u007f',
        '~//a',
      ]) {
        expect(validateLinkPath(bad), isNull, reason: bad);
      }
    });
  });

  group('round trip through #994 sftpUrlForRemotePath', () {
    for (final path in [
      '/',
      '/a/b',
      '/a b/c',
      '/a;b',
      '/%2e',
      '/a%20b',
      '/50%',
      '/café/ü',
      '/a/b/',
      '/q?x#y',
      '/[x]',
    ]) {
      test(path, () {
        final url = sftpUrlForRemotePath(
            username: 'u', host: 'h', port: 2222, path: path);
        final r = ok(url);
        expect(r.path, path, reason: url);
        expect(r.port, 2222);
        expect(r.user, 'u');
      });
    }
  });

  test('fuzz: 10k seeded mutations never throw and keep the F6 invariants',
      () {
    final rng = Random(1279);
    const seeds = [
      'sftp://h',
      'sftp://h/',
      'sftp://u@h:2222/a/b',
      'sftp://u@h/~',
      'sftp://u@h/~/x y',
      'sftp://u@[::1]/x',
      'sftp://u;fingerprint=ssh-ed25519-ab-cd@h/x',
      'SFTP://H/x',
      'sftp://h/a;b',
      'sftp://h/%252e',
      'mobissh://sftp?host=h&path=%2Fa%2Fb',
      'mobissh://sftp?name=al&path=~',
    ];
    const alphabet = [
      '%', '/', '.', '@', ':', ';', '~', '?', '#', '[', ']', ',', '=', '&',
      '2', 'e', 'E', 'F', 'f', '0', 'a', ' ', '\u0000', '\n', '\u007f', 'é',
      '%2e', '%2F', '%00', '..', '//', '%25',
    ];
    var accepted = 0;
    var roundTripped = 0;
    for (var i = 0; i < 10000; i++) {
      var s = seeds[rng.nextInt(seeds.length)];
      final edits = 1 + rng.nextInt(4);
      for (var e = 0; e < edits; e++) {
        final pos = s.isEmpty ? 0 : rng.nextInt(s.length + 1);
        final ins = alphabet[rng.nextInt(alphabet.length)];
        switch (rng.nextInt(3)) {
          case 0: // insert
            s = s.substring(0, pos) + ins + s.substring(pos);
          case 1: // replace
            if (pos < s.length) {
              s = s.substring(0, pos) + ins + s.substring(pos + 1);
            }
          default: // delete
            if (pos < s.length) s = s.substring(0, pos) + s.substring(pos + 1);
        }
      }
      final ConnectIntentResult r;
      try {
        r = parseLink(s);
      } catch (e) {
        fail('threw on ${jsonEncode(s)}: $e');
      }
      if (r is! ConnectIntentParsed) continue;
      accepted++;
      final path = r.request.path;
      if (path == null) continue;
      _expectInvariants(path, s);
      final host = r.request.host;
      // A first segment starting with `~` is home syntax in sftp://, so an
      // absolute `/~x` has no sftp:// spelling; everything else must round-trip.
      if (path.startsWith('/') && !path.startsWith('/~') && host != null) {
        final url = sftpUrlForRemotePath(
            username: r.request.user ?? 'u',
            host: host,
            port: r.request.port,
            path: path);
        final back = parseLink(url);
        expect(back, isA<ConnectIntentParsed>(),
            reason: 'round trip of ${jsonEncode(path)} via $url');
        expect((back as ConnectIntentParsed).request.path, path,
            reason: 'round trip via $url');
        roundTripped++;
      }
    }
    // The fuzz must actually exercise the accept side.
    expect(accepted, greaterThan(500));
    expect(roundTripped, greaterThan(100));
  });
}

void _expectInvariants(String path, String link) {
  final why = 'path ${jsonEncode(path)} from ${jsonEncode(link)}';
  expect(path.startsWith('/') || path == '~' || path.startsWith('~/'), isTrue,
      reason: why);
  expect(utf8.encode(path).length, lessThanOrEqualTo(4096), reason: why);
  for (final c in path.codeUnits) {
    expect(c >= 0x20 && c != 0x7f, isTrue, reason: why);
  }
  final segs = path.split('/').skip(1).toList();
  expect(segs.where((s) => s.isNotEmpty).length, lessThanOrEqualTo(64),
      reason: why);
  for (var i = 0; i < segs.length; i++) {
    final seg = segs[i];
    expect(seg == '.' || seg == '..', isFalse, reason: why);
    if (seg.isEmpty) {
      expect(i, segs.length - 1, reason: 'empty segment not trailing: $why');
    }
    expect(utf8.encode(seg).length, lessThanOrEqualTo(255), reason: why);
  }
}
