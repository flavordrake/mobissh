// #1279 S4 (D1) — `ssh://` links parse into the `connect` verb with the same
// rules as `sftp://` (docs/deep-link-intents.md §16): a password in the
// userinfo rejects the whole link (D2), `;fingerprint=` is shape-checked and
// ignored (D5), a path is ignored (not an error), a query or fragment rejects.
//
// API pinned: parseLink dispatches `ssh://` (any case) to a ConnectRequest with
// verb connect and path null.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/services/sftp_intent.dart';

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

void main() {
  group('accept table', () {
    test('ssh://h — the connect verb, default port, no user', () {
      final r = ok('ssh://h');
      expect(r.verb, ConnectVerb.connect);
      expect(r.host, 'h');
      expect(r.port, 22);
      expect(r.user, isNull);
      expect(r.path, isNull);
      expect(r.tmux, isNull);
    });

    test('ssh://u@h:2222 — user and port', () {
      final r = ok('ssh://u@h:2222');
      expect(r.user, 'u');
      expect(r.port, 2222);
    });

    test('ssh://u@127.0.0.1:2222 — the emulator acceptance link', () {
      final r = ok('ssh://testuser@127.0.0.1:2222');
      expect(r.host, '127.0.0.1');
      expect(r.user, 'testuser');
      expect(r.port, 2222);
    });

    test('SSH://U@Box.Example — scheme any case, host lower-cased', () {
      final r = ok('SSH://U@Box.Example');
      expect(r.host, 'box.example');
      expect(r.user, 'U');
    });

    test('ssh://u@[::1]:2200 — bracketed IPv6 stored without brackets', () {
      final r = ok('ssh://u@[::1]:2200');
      expect(r.host, '::1');
      expect(r.port, 2200);
    });

    test('ssh://u%40x@h — encoded @ in the user is decoded once and fails R4',
        () {
      rejects('ssh://u%40x@h', ConnectIntentReason.badParam, key: 'user');
    });

    test('D5: ;fingerprint= is parsed and ignored', () {
      final r = ok('ssh://u;fingerprint=ssh-ed25519-ab-cd@h');
      expect(r.user, 'u');
      expect(r.host, 'h');
    });

    test('RFC 4716 style unknown c-param is ignored', () {
      expect(ok('ssh://u;foo=bar@h').user, 'u');
    });

    test('a path is ignored, not an error, and never carried', () {
      expect(ok('ssh://u@h/').path, isNull);
      expect(ok('ssh://u@h/home/u').path, isNull);
      expect(ok('ssh://u@h/../../etc').path, isNull);
      expect(ok('ssh://u@h/a%2Fb').path, isNull);
    });

    test('the same request as the equivalent mobissh://connect link', () {
      final a = ok('ssh://alice@box.example:2200');
      final b =
          ok('mobissh://connect?host=box.example&port=2200&user=alice');
      expect(a.verb, b.verb);
      expect(a.host, b.host);
      expect(a.port, b.port);
      expect(a.user, b.user);
      expect(a.name, b.name);
      expect(a.tmux, b.tmux);
      expect(a.path, b.path);
    });

    test('MobiHarness-shaped host-only link ssh://user@host', () {
      final r = ok('ssh://matt@fd-dev');
      expect(r.host, 'fd-dev');
      expect(r.user, 'matt');
    });
  });

  group('D2: a credential in the link rejects the whole link', () {
    for (final bad in [
      'ssh://u:pw@h',
      'ssh://u:@h',
      'ssh://:pw@h',
      'ssh://u%3Apw@h',
      'ssh://u;fingerprint=a:b@h',
      'ssh://u:pw@h/x',
    ]) {
      test(bad, () {
        rejects(bad, ConnectIntentReason.credentialInLink);
      });
    }
  });

  group('reject table', () {
    test('two @', () {
      rejects('ssh://a@b@h', ConnectIntentReason.malformed);
    });
    test('empty userinfo', () {
      rejects('ssh://@h', ConnectIntentReason.badParam, key: 'user');
    });
    for (final bad in ['h:', 'h:0', 'h:65536', 'h:22a', 'h:-1']) {
      test('port $bad', () {
        rejects('ssh://$bad', ConnectIntentReason.badParam, key: 'port');
      });
    }
    test('hosts that are not R3 hosts', () {
      rejects('ssh://', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh:///x', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh://u@', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh://hôst', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh://h%C3%B4st', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh://-h', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh://h_x', ConnectIntentReason.badParam, key: 'host');
      rejects('ssh://[fe80::1%25eth0]', ConnectIntentReason.badParam,
          key: 'host');
      rejects('ssh://::1', ConnectIntentReason.badParam);
    });
    test('a leading dash cannot become an ssh option', () {
      rejects('ssh://-oProxyCommand=x', ConnectIntentReason.badParam,
          key: 'host');
      rejects('ssh://-oProxyCommand=x@h', ConnectIntentReason.badParam,
          key: 'user');
    });
    test('duplicate c-param', () {
      rejects('ssh://u;fingerprint=a,fingerprint=b@h',
          ConnectIntentReason.duplicateKey,
          key: 'fingerprint');
    });
    test('fingerprint outside its shape', () {
      rejects('ssh://u;fingerprint=a+b@h', ConnectIntentReason.badParam,
          key: 'fingerprint');
      rejects('ssh://u;fingerprint=@h', ConnectIntentReason.badParam,
          key: 'fingerprint');
    });
    test('query or fragment', () {
      rejects('ssh://h/?q', ConnectIntentReason.malformed);
      rejects('ssh://h?cmd=x', ConnectIntentReason.malformed);
      rejects('ssh://h#f', ConnectIntentReason.malformed);
    });
    test('control characters and whitespace', () {
      rejects('ssh://h\n', ConnectIntentReason.malformed);
      rejects(' ssh://h', ConnectIntentReason.malformed);
      rejects('ssh://h\u0000', ConnectIntentReason.malformed);
      rejects('ssh://u@h/\u007fx', ConnectIntentReason.malformed);
    });
    test('bad escape', () {
      rejects('ssh://u%zz@h', ConnectIntentReason.malformed);
      rejects('ssh://h%', ConnectIntentReason.malformed);
    });
    test('over-long link', () {
      rejects('ssh://h/${'a' * 8192}', ConnectIntentReason.tooLong);
    });
    test('another scheme is still not ssh', () {
      rejects('sshx://h', ConnectIntentReason.malformed);
      rejects('ssh:h', ConnectIntentReason.malformed);
      rejects('ssh:/h', ConnectIntentReason.malformed);
    });
  });

  test('fuzz: 10k seeded mutations never throw and keep the invariants', () {
    final rng = Random(1279004);
    const seeds = [
      'ssh://h',
      'ssh://u@h:2222',
      'ssh://u@h/home/u',
      'ssh://u@[::1]',
      'ssh://u;fingerprint=ssh-ed25519-ab-cd@h',
      'SSH://H',
      'ssh://u@h/a;b',
    ];
    const alphabet = [
      '%', '/', '.', '@', ':', ';', '~', '?', '#', '[', ']', ',', '=', '&',
      '2', 'e', 'a', ' ', '\u0000', '\n', '\u007f', 'é', '-', '%40', '%3A',
      '%2e', '%00', '..', '//', '%25',
    ];
    var accepted = 0;
    for (var i = 0; i < 10000; i++) {
      var s = seeds[rng.nextInt(seeds.length)];
      final edits = 1 + rng.nextInt(4);
      for (var e = 0; e < edits; e++) {
        final pos = s.isEmpty ? 0 : rng.nextInt(s.length + 1);
        final ins = alphabet[rng.nextInt(alphabet.length)];
        switch (rng.nextInt(3)) {
          case 0:
            s = s.substring(0, pos) + ins + s.substring(pos);
          case 1:
            if (pos < s.length) {
              s = s.substring(0, pos) + ins + s.substring(pos + 1);
            }
          default:
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
      final req = r.request;
      if (!s.toLowerCase().startsWith('ssh://')) continue;
      accepted++;
      final why = 'accepted ${jsonEncode(s)}';
      expect(req.verb, ConnectVerb.connect, reason: why);
      expect(req.path, isNull, reason: why);
      expect(req.tmux, isNull, reason: why);
      expect(req.host, isNotNull, reason: why);
      expect(req.host!.startsWith('-'), isFalse, reason: why);
      expect(req.port, inInclusiveRange(1, 65535), reason: why);
      expect(s.contains('?') || s.contains('#'), isFalse, reason: why);
      expect(hasLinkControlChar(s), isFalse, reason: why);
      final user = req.user;
      if (user != null) {
        expect(linkUserShape.hasMatch(user), isTrue, reason: why);
      }
      // D2: no accepted link has a colon in its userinfo.
      final rest = s.substring('ssh://'.length);
      final slash = rest.indexOf('/');
      final authority = slash < 0 ? rest : rest.substring(0, slash);
      final at = authority.indexOf('@');
      if (at >= 0) {
        // The user part, before any c-param (`;fingerprint=` values may hold
        // an encoded colon; the user may not).
        final info = authority.substring(0, at);
        final semi = info.indexOf(';');
        final userPart =
            (semi < 0 ? info : info.substring(0, semi)).toLowerCase();
        expect(userPart.contains(':') || userPart.contains('%3a'), isFalse,
            reason: why);
        expect(info.contains(':'), isFalse, reason: why);
      }
    }
    expect(accepted, greaterThan(500));
  });
}
