// #1139 (PR A of #1117) — `mobissh://` ConnectRequest parser + profile matcher.
// Encodes docs/deep-link-intents.md R1–R11 and acceptance items A1–A3.
//
// Pure Dart: no widget imports, no platform wiring, no store I/O. Fixture
// profiles are built with the `SavedProfile` constructor from
// lib/storage/profiles_store.dart; the link alias is NOT a profile field yet
// (PR B adds it), so the matcher takes an injected alias accessor.
//
// API SURFACE PINNED BY THESE TESTS (lib/services/connect_intent.dart):
//
//   enum ConnectVerb { connect, create }
//
//   class ConnectRequest {
//     const ConnectRequest({
//       required this.verb, this.host, this.port = 22,
//       this.user, this.name, this.tmux,
//     });
//     final ConnectVerb verb;
//     final String? host;   // canonical (lower-cased); IPv6 without brackets
//     final int port;       // default 22
//     final String? user;
//     final String? name;   // link alias on connect / label on create
//     final String? tmux;   // validated per R6 (grammar locked; no wiring)
//   }
//
//   enum ConnectIntentReason { malformed, unknownVerb, badParam, duplicateKey, reserved }
//
//   sealed class ConnectIntentResult { const ConnectIntentResult(); }
//   final class ConnectIntentParsed extends ConnectIntentResult {
//     const ConnectIntentParsed(this.request);
//     final ConnectRequest request;
//   }
//   final class ConnectIntentRejected extends ConnectIntentResult {
//     const ConnectIntentRejected(this.reason, {this.key});
//     final ConnectIntentReason reason;
//     final String? key;    // the offending param for badParam/duplicateKey/reserved
//   }
//
//   ConnectIntentResult parseConnectIntent(String link);
//
//   sealed class ConnectMatch { const ConnectMatch(); }
//   final class Matched extends ConnectMatch {
//     const Matched(this.profile);
//     final SavedProfile profile;
//   }
//   final class Ambiguous extends ConnectMatch {
//     const Ambiguous(this.candidates);
//     final List<SavedProfile> candidates;
//   }
//   final class NoMatch extends ConnectMatch { const NoMatch(); }
//   final class AliasMiss extends ConnectMatch { const AliasMiss(); }
//
//   ConnectMatch matchConnectRequest(
//     ConnectRequest request,
//     List<SavedProfile> profiles, {
//     required String? Function(SavedProfile) alias,
//   });
//
// Reason mapping pinned here (the doc leaves the label to the implementation):
//   - wrong scheme, no verb, path after the verb, missing required param,
//     whitespace/control char in a value or around the link  -> malformed
//   - authority that is not `connect`/`create`               -> unknownVerb
//   - a known param failing its R3–R6 rule, or `tmux` on `create` -> badParam(key)
//   - a key appearing twice                                   -> duplicateKey(key)
//   - `claude=`                                               -> reserved('claude')
// Bracketed IPv6 is accepted and stored WITHOUT brackets: the brackets are URI
// syntax, the raw address is what the socket layer takes.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/storage/profiles_store.dart';

/// Parse a link that MUST be accepted and unwrap the request.
ConnectRequest parseOk(String link) {
  final r = parseConnectIntent(link);
  expect(r, isA<ConnectIntentParsed>(), reason: 'expected accept: $link');
  return (r as ConnectIntentParsed).request;
}

/// Parse a link that MUST be rejected and unwrap the rejection.
ConnectIntentRejected parseRejected(String link) {
  final r = parseConnectIntent(link);
  expect(r, isA<ConnectIntentRejected>(), reason: 'expected reject: $link');
  return r as ConnectIntentRejected;
}

void expectReject(String link, ConnectIntentReason reason, {String? key}) {
  final r = parseRejected(link);
  expect(r.reason, reason, reason: 'reason for: $link');
  if (key != null) expect(r.key, key, reason: 'key for: $link');
}

void expectBadParam(String link, String key) =>
    expectReject(link, ConnectIntentReason.badParam, key: key);

SavedProfile profile(String title, String host, int port, String user) =>
    SavedProfile(title: title, host: host, port: port, username: user);

void main() {
  group('A1 grammar — every §3 row parses to the expected ConnectRequest', () {
    test('connect?host=<fqdn> — port defaults to 22, other fields absent', () {
      final r = parseOk('mobissh://connect?host=box.example.com');
      expect(r.verb, ConnectVerb.connect);
      expect(r.host, 'box.example.com');
      expect(r.port, 22);
      expect(r.user, isNull);
      expect(r.name, isNull);
      expect(r.tmux, isNull);
    });

    test('connect?host&port&user — all three fields carried', () {
      final r =
          parseOk('mobissh://connect?host=box.example.com&port=2222&user=dev');
      expect(r.verb, ConnectVerb.connect);
      expect(r.host, 'box.example.com');
      expect(r.port, 2222);
      expect(r.user, 'dev');
      expect(r.name, isNull);
    });

    test('connect?name=<alias> — alias only, no host', () {
      final r = parseOk('mobissh://connect?name=prod-box_1');
      expect(r.verb, ConnectVerb.connect);
      expect(r.name, 'prod-box_1');
      expect(r.host, isNull);
      expect(r.port, 22);
      expect(r.user, isNull);
    });

    test('create?host=<fqdn> — create verb with default port', () {
      final r = parseOk('mobissh://create?host=box.example.com');
      expect(r.verb, ConnectVerb.create);
      expect(r.host, 'box.example.com');
      expect(r.port, 22);
      expect(r.user, isNull);
      expect(r.name, isNull);
    });

    test('create?host&port&user&name — label carried on create', () {
      final r = parseOk(
        'mobissh://create?host=box.example.com&port=2222&user=dev&name=my_label',
      );
      expect(r.verb, ConnectVerb.create);
      expect(r.host, 'box.example.com');
      expect(r.port, 2222);
      expect(r.user, 'dev');
      expect(r.name, 'my_label');
    });

    test('connect with tmux=<name> — token carried verbatim', () {
      final r = parseOk('mobissh://connect?host=box.example.com&tmux=work');
      expect(r.verb, ConnectVerb.connect);
      expect(r.host, 'box.example.com');
      expect(r.tmux, 'work');
    });

    test('host is lower-cased on parse (R3)', () {
      final r = parseOk('mobissh://connect?host=Box.Example.COM');
      expect(r.host, 'box.example.com');
    });

    test('IPv4 literal is a valid host', () {
      final r = parseOk('mobissh://connect?host=10.0.0.5');
      expect(r.host, '10.0.0.5');
    });

    test('bracketed IPv6 is accepted; stored without brackets, lower-cased',
        () {
      final r = parseOk('mobissh://connect?host=[FE80::1]');
      expect(r.host, 'fe80::1');
    });

    test('percent-encoded bracketed IPv6 is accepted too', () {
      final r = parseOk('mobissh://connect?host=%5Bfe80%3A%3A1%5D&port=2200');
      expect(r.host, 'fe80::1');
      expect(r.port, 2200);
    });

    test('port boundaries 1 and 65535 are accepted (R4)', () {
      expect(parseOk('mobissh://connect?host=h.example.com&port=1').port, 1);
      expect(
        parseOk('mobissh://connect?host=h.example.com&port=65535').port,
        65535,
      );
    });

    test('unknown parameters are ignored (R7)', () {
      final r = parseOk(
        'mobissh://connect?host=box.example.com&foo=bar&return=x%3A%2F%2Fy',
      );
      expect(r.host, 'box.example.com');
      expect(r.port, 22);
      expect(r.user, isNull);
      expect(r.name, isNull);
      expect(r.tmux, isNull);
    });
  });

  group('A1 decoding — percent-decode exactly once (R2)', () {
    test('a single-encoded value is decoded', () {
      final r = parseOk('mobissh://connect?host=box%2Eexample%2Ecom&user=a%2Eb');
      expect(r.host, 'box.example.com');
      expect(r.user, 'a.b');
    });

    test('a double-encoded host stays encoded after one decode and is rejected',
        () {
      // One decode yields `box%2Eexample.com` — `%` is not a hostname char.
      // A second decode would yield a VALID host, so acceptance here would
      // prove a double decode.
      expectBadParam('mobissh://connect?host=box%252Eexample.com', 'host');
    });

    test('a double-encoded user stays encoded after one decode and is rejected',
        () {
      // `a%252Eb` -> `a%2Eb` (invalid user); a second decode -> `a.b` (valid).
      expectBadParam('mobissh://connect?host=box.example.com&user=a%252Eb',
          'user');
    });
  });

  group('A1 whitespace and control characters reject as malformed (R2)', () {
    test('trailing space in a value', () {
      expectReject('mobissh://connect?host=box.example.com%20',
          ConnectIntentReason.malformed);
    });

    test('leading space in a value', () {
      expectReject('mobissh://connect?host=%20box.example.com',
          ConnectIntentReason.malformed);
    });

    test('trailing space on a user value', () {
      expectReject('mobissh://connect?host=box.example.com&user=dev%20',
          ConnectIntentReason.malformed);
    });

    test('trailing whitespace on the link itself', () {
      expectReject('mobissh://connect?host=box.example.com ',
          ConnectIntentReason.malformed);
    });

    test('leading whitespace on the link itself', () {
      expectReject(' mobissh://connect?host=box.example.com',
          ConnectIntentReason.malformed);
    });

    test('NUL inside a value', () {
      expectReject('mobissh://connect?host=box%00example.com',
          ConnectIntentReason.malformed);
    });

    test('newline inside a value', () {
      expectReject('mobissh://connect?host=box.example.com&user=dev%0Aops',
          ConnectIntentReason.malformed);
    });

    test('tab inside a value', () {
      expectReject('mobissh://connect?host=box.example.com&name=a%09b',
          ConnectIntentReason.malformed);
    });
  });

  group('A1 duplicate keys reject as duplicateKey (R2)', () {
    test('host twice', () {
      expectReject(
        'mobissh://connect?host=a.example.com&host=b.example.com',
        ConnectIntentReason.duplicateKey,
        key: 'host',
      );
    });

    test('port twice, even with identical values', () {
      expectReject(
        'mobissh://connect?host=a.example.com&port=22&port=22',
        ConnectIntentReason.duplicateKey,
        key: 'port',
      );
    });

    test('name twice on connect', () {
      expectReject(
        'mobissh://connect?name=one&name=two',
        ConnectIntentReason.duplicateKey,
        key: 'name',
      );
    });
  });

  group('A1 host rule violations reject as badParam(host) (R3)', () {
    test('userinfo inside host', () {
      expectBadParam('mobissh://connect?host=dev@box.example.com', 'host');
    });

    test('userinfo with password inside host', () {
      expectBadParam('mobissh://connect?host=user:pw@h', 'host');
    });

    test('path inside host', () {
      expectBadParam('mobissh://connect?host=box.example.com/etc', 'host');
    });

    test('port inside host', () {
      expectBadParam('mobissh://connect?host=box.example.com:22', 'host');
    });

    test('empty host', () {
      expectBadParam('mobissh://connect?host=', 'host');
    });

    test('label starting with a hyphen', () {
      expectBadParam('mobissh://connect?host=-box.example.com', 'host');
    });

    test('label ending with a hyphen', () {
      expectBadParam('mobissh://connect?host=box-.example.com', 'host');
    });

    test('underscore in a label', () {
      expectBadParam('mobissh://connect?host=box_1.example.com', 'host');
    });

    test('empty label (double dot)', () {
      expectBadParam('mobissh://connect?host=box..example.com', 'host');
    });

    test('label longer than 63 characters', () {
      final label = 'a' * 64;
      expectBadParam('mobissh://connect?host=$label.example.com', 'host');
    });

    test('label of exactly 63 characters is accepted', () {
      final label = 'a' * 63;
      expect(
        parseOk('mobissh://connect?host=$label.example.com').host,
        '$label.example.com',
      );
    });

    test('unbracketed IPv6 (colons read as a port) is rejected', () {
      expectBadParam('mobissh://connect?host=fe80::1', 'host');
    });

    test('a scheme inside host', () {
      expectBadParam('mobissh://connect?host=ssh%3A%2F%2Fbox.example.com',
          'host');
    });
  });

  group('A1 port rule violations reject as badParam(port) (R4)', () {
    for (final bad in ['0', '65536', 'abc', '', '22a', '-1', '1.5']) {
      test('port=$bad', () {
        expectBadParam('mobissh://connect?host=box.example.com&port=$bad',
            'port');
      });
    }
  });

  group('A1 user rule (R4)', () {
    test('64-character user is accepted', () {
      final u = 'u' * 64;
      expect(parseOk('mobissh://connect?host=box.example.com&user=$u').user, u);
    });

    test('65-character user is rejected', () {
      final u = 'u' * 65;
      expectBadParam('mobissh://connect?host=box.example.com&user=$u', 'user');
    });

    test('full allowed alphabet is accepted', () {
      expect(
        parseOk('mobissh://connect?host=box.example.com&user=a.b_c-D9').user,
        'a.b_c-D9',
      );
    });

    test('empty user is rejected', () {
      expectBadParam('mobissh://connect?host=box.example.com&user=', 'user');
    });

    test('inner space is rejected', () {
      expectBadParam('mobissh://connect?host=box.example.com&user=dev%20ops',
          'user');
    });

    test('slash is rejected', () {
      expectBadParam('mobissh://connect?host=box.example.com&user=a%2Fb',
          'user');
    });

    test('@ is rejected', () {
      expectBadParam('mobissh://connect?host=box.example.com&user=a%40b',
          'user');
    });
  });

  group('A1 name rule (R5)', () {
    test('32-character name is accepted', () {
      final n = 'n' * 32;
      expect(parseOk('mobissh://connect?name=$n').name, n);
    });

    test('33-character name is rejected', () {
      final n = 'n' * 33;
      expectBadParam('mobissh://connect?name=$n', 'name');
    });

    test('dot is not allowed in a name', () {
      expectBadParam('mobissh://connect?name=prod.box', 'name');
    });

    test('empty name is rejected', () {
      expectBadParam('mobissh://connect?name=', 'name');
    });

    test('the same rule applies to the create label', () {
      expectBadParam('mobissh://create?host=box.example.com&name=my.label',
          'name');
    });
  });

  group('A1 tmux rule (R6, no leading hyphen)', () {
    const base = 'mobissh://connect?host=box.example.com';

    test('tmux=-foo is rejected', () {
      expectBadParam('$base&tmux=-foo', 'tmux');
    });

    test('tmux=foo-bar parses', () {
      expect(parseOk('$base&tmux=foo-bar').tmux, 'foo-bar');
    });

    test('tmux=_foo parses (leading underscore allowed)', () {
      expect(parseOk('$base&tmux=_foo').tmux, '_foo');
    });

    test('32-character tmux name parses', () {
      final t = 't' * 32;
      expect(parseOk('$base&tmux=$t').tmux, t);
    });

    test('33-character tmux name is rejected', () {
      final t = 't' * 33;
      expectBadParam('$base&tmux=$t', 'tmux');
    });

    test('dot is not allowed in a tmux name', () {
      expectBadParam('$base&tmux=foo.bar', 'tmux');
    });

    test('empty tmux is rejected', () {
      expectBadParam('$base&tmux=', 'tmux');
    });

    test('tmux on create is rejected (v1.1 verbs are connect-only)', () {
      expectBadParam('mobissh://create?host=box.example.com&tmux=work',
          'tmux');
    });
  });

  group('A1 required parameters (§3)', () {
    test('connect without host or name is malformed', () {
      expectReject('mobissh://connect', ConnectIntentReason.malformed);
    });

    test('connect with an empty query is malformed', () {
      expectReject('mobissh://connect?', ConnectIntentReason.malformed);
    });

    test('connect with only port/user is malformed', () {
      expectReject(
          'mobissh://connect?port=22&user=dev', ConnectIntentReason.malformed);
    });

    test('create without host is malformed', () {
      expectReject('mobissh://create', ConnectIntentReason.malformed);
    });

    test('create with only a label is malformed (host is required)', () {
      expectReject(
          'mobissh://create?name=label', ConnectIntentReason.malformed);
    });
  });

  group('A2 scheme and verb (R1)', () {
    test('ssh:// is rejected as malformed', () {
      expectReject(
          'ssh://dev@box.example.com', ConnectIntentReason.malformed);
    });

    test('mobissh://open is an unknown verb', () {
      expectReject('mobissh://open?host=box.example.com',
          ConnectIntentReason.unknownVerb);
    });

    test('mobissh://connect?host=user:pw@h is a bad host', () {
      expectBadParam('mobissh://connect?host=user:pw@h', 'host');
    });

    test('empty string is malformed', () {
      expectReject('', ConnectIntentReason.malformed);
    });

    test('mobissh:// alone is malformed', () {
      expectReject('mobissh://', ConnectIntentReason.malformed);
    });

    test('a path segment after the verb is malformed', () {
      expectReject('mobissh://connect/extra?host=box.example.com',
          ConnectIntentReason.malformed);
    });

    test('a non-URL string is malformed', () {
      expectReject('not a link', ConnectIntentReason.malformed);
    });

    test('https:// with the right shape is still malformed', () {
      expectReject('https://connect?host=box.example.com',
          ConnectIntentReason.malformed);
    });
  });

  group('Negative — reserved claude= rejects the whole link (R7/R24)', () {
    const uuid = '123e4567-e89b-12d3-a456-426614174000';

    test('claude=<uuid> with every other param valid is reserved', () {
      expectReject(
        'mobissh://connect?host=box.example.com&port=22&user=dev&claude=$uuid',
        ConnectIntentReason.reserved,
        key: 'claude',
      );
    });

    test('claude= alongside a valid tmux is still reserved', () {
      expectReject(
        'mobissh://connect?host=box.example.com&tmux=work&claude=$uuid',
        ConnectIntentReason.reserved,
        key: 'claude',
      );
    });

    test('claude= on an alias link is reserved', () {
      expectReject(
        'mobissh://connect?name=box&claude=$uuid',
        ConnectIntentReason.reserved,
        key: 'claude',
      );
    });

    test('claude= with a non-UUID value never degrades to a plain connect', () {
      parseRejected('mobissh://connect?host=box.example.com&claude=nope');
    });
  });

  group('A3 matching (R8–R11)', () {
    // Two users on one host:port, one alt-port profile, one mixed-case host,
    // one other host. Titles are distinct so the alias accessor can key on
    // them (the alias field itself lands in PR B).
    final dev = profile('Box', 'box.example.com', 22, 'dev');
    final ops = profile('Box ops', 'box.example.com', 22, 'ops');
    final altPort = profile('Box alt', 'box.example.com', 2222, 'dev');
    final mixed = profile('Mixed', 'Mixed.Example.COM', 22, 'dev');
    final other = profile('Other', 'other.example.com', 22, 'dev');
    final store = [dev, ops, altPort, mixed, other];

    String? aliasByTitle(SavedProfile p) => switch (p.title) {
          'Box' => 'box',
          'Other' => 'other',
          _ => null,
        };

    String? noAlias(SavedProfile p) => null;

    ConnectMatch match(ConnectRequest req,
            {List<SavedProfile>? profiles,
            String? Function(SavedProfile)? alias}) =>
        matchConnectRequest(req, profiles ?? store,
            alias: alias ?? aliasByTitle);

    SavedProfile matched(ConnectMatch m) {
      expect(m, isA<Matched>());
      return (m as Matched).profile;
    }

    List<SavedProfile> ambiguous(ConnectMatch m) {
      expect(m, isA<Ambiguous>());
      return (m as Ambiguous).candidates;
    }

    test('exact host+port+user matches that one profile', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com', user: 'dev'));
      expect(matched(m), same(dev));
    });

    test('with user given, the OTHER user on the same host:port is chosen',
        () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com', user: 'ops'));
      expect(matched(m), same(ops));
    });

    test('with user given and no such user, never falls back to host-only',
        () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect,
          host: 'box.example.com',
          user: 'nobody'));
      expect(m, isA<NoMatch>());
    });

    test('username is byte-exact (no case folding)', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com', user: 'Dev'));
      expect(m, isA<NoMatch>());
    });

    test('port is compared as an int: explicit 2222 picks the alt profile',
        () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect,
          host: 'box.example.com',
          port: 2222,
          user: 'dev'));
      expect(matched(m), same(altPort));
    });

    test('default port 22 does not match a profile stored on 2222', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com', user: 'dev'));
      expect(matched(m), isNot(same(altPort)));
    });

    test('host-only with a single profile on that host:port matches it', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'other.example.com'));
      expect(matched(m), same(other));
    });

    test('host-only with an explicit port narrows to that port', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com', port: 2222));
      expect(matched(m), same(altPort));
    });

    test('host-only with two users on one host:port is Ambiguous with both',
        () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com'));
      expect(ambiguous(m), unorderedEquals([dev, ops]));
    });

    test('host-only ambiguity excludes the profile on another port', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'box.example.com'));
      expect(ambiguous(m), isNot(contains(altPort)));
    });

    test('Ambiguous is order-independent (store order reversed)', () {
      final m = match(
        const ConnectRequest(
            verb: ConnectVerb.connect, host: 'box.example.com'),
        profiles: store.reversed.toList(),
      );
      expect(ambiguous(m), unorderedEquals([dev, ops]));
    });

    test('stored mixed-case host matches a lower-cased link host', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'mixed.example.com', user: 'dev'));
      expect(matched(m), same(mixed));
    });

    test('the matched profile carries the STORED host spelling', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'mixed.example.com', user: 'dev'));
      expect(matched(m).host, 'Mixed.Example.COM');
    });

    test('canonicalisation is applied to BOTH sides (link side too)', () {
      // A request built directly (bypassing the parser's lower-casing) must
      // still match: the matcher canonicalises its own input, not only the
      // stored value.
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'MIXED.example.COM', user: 'dev'));
      expect(matched(m), same(mixed));
    });

    test('a parsed link end-to-end matches the stored profile', () {
      final req = parseOk('mobissh://connect?host=Box.Example.com&user=ops');
      expect(matched(match(req)), same(ops));
    });

    test('alias hit resolves through the accessor', () {
      final m = match(
          const ConnectRequest(verb: ConnectVerb.connect, name: 'other'));
      expect(matched(m), same(other));
    });

    test('alias miss is AliasMiss, not NoMatch', () {
      final m = match(
          const ConnectRequest(verb: ConnectVerb.connect, name: 'nope'));
      expect(m, isA<AliasMiss>());
    });

    test('alias never resolves through the title', () {
      final m = match(
        const ConnectRequest(verb: ConnectVerb.connect, name: 'Box'),
        alias: noAlias,
      );
      expect(m, isA<AliasMiss>());
    });

    test('alias never resolves through the host', () {
      final m = match(
        const ConnectRequest(verb: ConnectVerb.connect, name: 'box'),
        alias: noAlias,
      );
      expect(m, isA<AliasMiss>());
    });

    test('the same alias on two profiles is Ambiguous with both (R10)', () {
      String? dupAlias(SavedProfile p) =>
          (p.title == 'Box' || p.title == 'Other') ? 'dup' : null;
      final m = match(
        const ConnectRequest(verb: ConnectVerb.connect, name: 'dup'),
        alias: dupAlias,
      );
      expect(ambiguous(m), unorderedEquals([dev, other]));
    });

    test('a duplicated alias never resolves to the first hit', () {
      String? dupAlias(SavedProfile p) =>
          (p.title == 'Box' || p.title == 'Other') ? 'dup' : null;
      final m = match(
        const ConnectRequest(verb: ConnectVerb.connect, name: 'dup'),
        alias: dupAlias,
      );
      expect(m, isNot(isA<Matched>()));
    });

    test('unknown host is NoMatch', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.connect, host: 'nowhere.example.com'));
      expect(m, isA<NoMatch>());
    });

    test('an empty store is NoMatch', () {
      final m = match(
        const ConnectRequest(
            verb: ConnectVerb.connect, host: 'box.example.com', user: 'dev'),
        profiles: const [],
      );
      expect(m, isA<NoMatch>());
    });

    test('create with an existing identity is Matched (R11)', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.create, host: 'box.example.com', user: 'dev'));
      expect(matched(m), same(dev));
    });

    test('create with an existing identity on the alt port is Matched', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.create,
          host: 'BOX.example.com',
          port: 2222,
          user: 'dev'));
      expect(matched(m), same(altPort));
    });

    test('create with an unknown identity is NoMatch', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.create, host: 'new.example.com', user: 'dev'));
      expect(m, isA<NoMatch>());
    });

    test('create with a known host but unknown user is NoMatch', () {
      final m = match(const ConnectRequest(
          verb: ConnectVerb.create, host: 'box.example.com', user: 'nobody'));
      expect(m, isA<NoMatch>());
    });
  });
}
