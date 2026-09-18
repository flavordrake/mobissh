// A9 (#1184, spec docs/jump-host.md R18/R20) — resolving parsed `ProxyJump`
// hops against the saved profiles at IMPORT time.
//
// The invariant under test: an unresolved hop NEVER produces a
// `jumpIdentityKey`. A dangling reference would resolve to "no jump host" at
// connect time (R1) — i.e. the session would silently go DIRECT to a host the
// config says must be reached through a bastion.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/jump_host.dart' show kMaxJumpHops;
import 'package:mobissh/ssh/ssh_config_jump_import.dart';
import 'package:mobissh/ssh/ssh_config_parser.dart';
import 'package:mobissh/storage/profiles_store.dart';

SavedProfile _p(
  String title,
  String host, {
  int port = 22,
  String user = 'me',
  String? alias,
  String? jump,
}) => SavedProfile(
  title: title,
  host: host,
  port: port,
  username: user,
  linkAlias: alias,
  jumpIdentityKey: jump,
);

List<SshJumpHop> _hops(String proxyJumpValue) =>
    parseSshConfig('Host t\n  ProxyJump $proxyJumpValue\n').single.proxyJump;

void main() {
  final target = _p('prod', 'prod.example.com');

  group('resolveImportedJumpHops (R18)', () {
    test('an alias hop resolves against a profile linkAlias', () {
      final bastion = _p('bastion', 'bastion.example.com', alias: 'bastion');
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('bastion'),
        profiles: [target, bastion],
      );
      expect(out.jumpIdentityKey, bastion.identityKey);
      expect(out.missing, isEmpty);
      expect(out.chainLinks, isEmpty);
    });

    test('a literal user@host:port hop resolves by identity', () {
      final bastion = _p(
        'jump',
        'bastion.example.com',
        port: 2222,
        user: 'jumpuser',
      );
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('jumpuser@bastion.example.com:2222'),
        profiles: [target, bastion],
      );
      expect(out.jumpIdentityKey, 'bastion.example.com:2222:jumpuser');
      expect(out.missing, isEmpty);
    });

    test('a bare alias also resolves through the pasted config own stanza', () {
      // `ProxyJump bastion` + a `Host bastion` stanza in the SAME paste: the
      // alias names a stanza, and the stanza names the real host — which IS a
      // saved profile.
      final cfg = parseSshConfig(
        'Host prod\n  HostName prod.example.com\n  ProxyJump bastion\n'
        'Host bastion\n  HostName 10.0.0.5\n  User ops\n',
      );
      final bastion = _p('ops@10.0.0.5', '10.0.0.5', user: 'ops');
      final out = resolveImportedJumpHops(
        target: target,
        hops: cfg.first.proxyJump,
        profiles: [target, bastion],
        entries: cfg,
      );
      expect(out.jumpIdentityKey, bastion.identityKey);
    });

    test('an UNRESOLVED alias imports NO link and says to create it first', () {
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('bastion'),
        profiles: [target],
      );
      expect(
        out.jumpIdentityKey,
        isNull,
        reason: 'a dangling jumpIdentityKey would silently connect DIRECT',
      );
      expect(out.missing.map((h) => h.spec), ['bastion']);
      expect(out.notes.single, contains('bastion'));
      expect(out.notes.single.toLowerCase(), contains('create'));
    });

    test('one unresolved hop in a chain blocks the WHOLE import', () {
      final a = _p('a', 'a.example.com', alias: 'a');
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('a,b'),
        profiles: [target, a],
      );
      expect(out.jumpIdentityKey, isNull);
      expect(out.chainLinks, isEmpty);
      expect(out.missing.map((h) => h.spec), ['b']);
    });

    test('a hop that IS the edited profile is refused as a loop', () {
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('me@prod.example.com:22'),
        profiles: [target],
      );
      expect(out.jumpIdentityKey, isNull);
      expect(out.notes.single.toLowerCase(), contains('loop'));
    });
  });

  group('resolveImportedJumpHops — chains (R20)', () {
    test('a,b links the target to b and b to a', () {
      final a = _p('a', 'a.example.com', alias: 'a');
      final b = _p('b', 'b.example.com', alias: 'b');
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('a,b'),
        profiles: [target, a, b],
      );
      // ssh dials a first, then b, then the target: the target's DIRECT jump
      // host is the innermost hop.
      expect(out.jumpIdentityKey, b.identityKey);
      expect(out.chainLinks, hasLength(1));
      expect(out.chainLinks.single.hop.identityKey, b.identityKey);
      expect(out.chainLinks.single.jumpIdentityKey, a.identityKey);
    });

    test('an already-correct intermediate link is not rewritten', () {
      final a = _p('a', 'a.example.com', alias: 'a');
      final b = _p('b', 'b.example.com', alias: 'b', jump: a.identityKey);
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('a,b'),
        profiles: [target, a, b],
      );
      expect(out.jumpIdentityKey, b.identityKey);
      expect(out.chainLinks, isEmpty);
    });

    test('a chain deeper than kMaxJumpHops imports nothing, and says so', () {
      final profiles = <SavedProfile>[target];
      for (final n in ['a', 'b', 'c', 'd']) {
        profiles.add(_p(n, '$n.example.com', alias: n));
      }
      final out = resolveImportedJumpHops(
        target: target,
        hops: _hops('a,b,c,d'),
        profiles: profiles,
      );
      expect(out.jumpIdentityKey, isNull);
      expect(out.chainLinks, isEmpty);
      expect(out.notes.single, contains('$kMaxJumpHops'));
    });

    test('no hops is a no-op', () {
      final out = resolveImportedJumpHops(
        target: target,
        hops: const [],
        profiles: [target],
      );
      expect(out.jumpIdentityKey, isNull);
      expect(out.notes, isEmpty);
      expect(out.missing, isEmpty);
    });
  });
}
