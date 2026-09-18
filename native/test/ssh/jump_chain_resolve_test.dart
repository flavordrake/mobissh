// A1 — jump-chain resolution (#1183, spec docs/jump-host.md R1-R4).
//
// `resolveJumpChain(target, all)` follows `SavedProfile.jumpIdentityKey`
// transitively and returns the hops OUTERMOST-FIRST (the profile you dial
// first is index 0). It never returns the target itself.
//
// Fail-closed cases throw [JumpChainError] rather than silently truncating:
// a chain deeper than [kMaxJumpHops] (R3) and any cycle, self-reference
// included (R4). A DANGLING reference — a jumpIdentityKey no profile
// matches — is "no jump host" (R1: absent/unknown/corrupt → none), because a
// referenced profile the user deleted must not brick the connect path.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ssh/jump_host.dart';
import 'package:mobissh/storage/profiles_store.dart';

SavedProfile _p(String host, {String? jump, int port = 22, String user = 'me'}) =>
    SavedProfile(
      title: host,
      host: host,
      port: port,
      username: user,
      jumpIdentityKey: jump,
    );

String _key(String host, {int port = 22, String user = 'me'}) =>
    '$host:$port:$user';

void main() {
  group('resolveJumpChain — happy paths (R1, R3)', () {
    test('a profile with no jumpIdentityKey resolves to an empty chain', () {
      final target = _p('target.example');
      expect(resolveJumpChain(target, [target]), isEmpty);
    });

    test('one hop resolves to that single profile', () {
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: _key('bastion.example'));

      final chain = resolveJumpChain(target, [bastion, target]);

      expect(chain, hasLength(1));
      expect(chain.single.host, 'bastion.example');
    });

    test('three hops resolve OUTERMOST-FIRST (R7 dial order)', () {
      // outer -> mid -> inner -> target
      final outer = _p('outer.example');
      final mid = _p('mid.example', jump: _key('outer.example'));
      final inner = _p('inner.example', jump: _key('mid.example'));
      final target = _p('target.example', jump: _key('inner.example'));

      final chain = resolveJumpChain(target, [target, inner, mid, outer]);

      expect(
        chain.map((p) => p.host).toList(),
        ['outer.example', 'mid.example', 'inner.example'],
        reason: 'index 0 is the hop dialled FIRST',
      );
      expect(chain.length, kMaxJumpHops);
    });

    test('the chain never contains the target itself', () {
      final bastion = _p('bastion.example');
      final target = _p('target.example', jump: _key('bastion.example'));

      final chain = resolveJumpChain(target, [bastion, target]);

      expect(chain.any((p) => p.identityKey == target.identityKey), isFalse);
    });

    test('a hop is matched by identityKey, not by host alone (R1/D1)', () {
      // Same host, different port/user — only the exact identity is the hop.
      final wrongPort = _p('bastion.example', port: 2222);
      final right = _p('bastion.example');
      final target = _p('target.example', jump: _key('bastion.example'));

      final chain = resolveJumpChain(target, [wrongPort, right, target]);

      expect(chain.single.port, 22);
    });
  });

  group('resolveJumpChain — fail closed (R3 depth cap)', () {
    test('a depth-4 chain throws JumpChainError(tooDeep)', () {
      final h1 = _p('h1.example');
      final h2 = _p('h2.example', jump: _key('h1.example'));
      final h3 = _p('h3.example', jump: _key('h2.example'));
      final h4 = _p('h4.example', jump: _key('h3.example'));
      final target = _p('target.example', jump: _key('h4.example'));

      expect(
        () => resolveJumpChain(target, [h1, h2, h3, h4, target]),
        throwsA(
          isA<JumpChainError>()
              .having((e) => e.reason, 'reason', JumpChainErrorReason.tooDeep)
              .having(
                (e) => e.toString(),
                'message names the cap and the target',
                allOf(contains('target.example'), contains('$kMaxJumpHops')),
              ),
        ),
      );
    });

    test('kMaxJumpHops is 3 (spec R3)', () {
      expect(kMaxJumpHops, 3);
    });
  });

  group('resolveJumpChain — fail closed (R4 cycles)', () {
    test('a self-reference throws JumpChainError(cycle)', () {
      final target = _p('target.example', jump: _key('target.example'));

      expect(
        () => resolveJumpChain(target, [target]),
        throwsA(
          isA<JumpChainError>()
              .having((e) => e.reason, 'reason', JumpChainErrorReason.cycle)
              .having(
                (e) => e.identityKey,
                'identityKey names the offending profile',
                _key('target.example'),
              ),
        ),
      );
    });

    test('a two-profile cycle throws JumpChainError(cycle)', () {
      final a = _p('a.example', jump: _key('b.example'));
      final b = _p('b.example', jump: _key('a.example'));

      expect(
        () => resolveJumpChain(a, [a, b]),
        throwsA(
          isA<JumpChainError>().having(
            (e) => e.reason,
            'reason',
            JumpChainErrorReason.cycle,
          ),
        ),
      );
    });

    test('a three-profile cycle throws cycle, not tooDeep', () {
      // a -> b -> c -> a. Depth would also hit the cap; the CYCLE is the more
      // specific (and actionable) diagnosis, so it must win.
      final a = _p('a.example', jump: _key('b.example'));
      final b = _p('b.example', jump: _key('c.example'));
      final c = _p('c.example', jump: _key('a.example'));

      expect(
        () => resolveJumpChain(a, [a, b, c]),
        throwsA(
          isA<JumpChainError>().having(
            (e) => e.reason,
            'reason',
            JumpChainErrorReason.cycle,
          ),
        ),
      );
    });
  });

  group('resolveJumpChain — dangling references (R1 corrupt-resilience)', () {
    test('a jumpIdentityKey no profile matches resolves to no jump host', () {
      final target = _p('target.example', jump: _key('deleted.example'));

      expect(resolveJumpChain(target, [target]), isEmpty);
    });

    test('a dangling reference DEEP in the chain truncates, it does not throw', () {
      // target -> inner (exists) -> gone (deleted). The reachable part stands.
      final inner = _p('inner.example', jump: _key('gone.example'));
      final target = _p('target.example', jump: _key('inner.example'));

      final chain = resolveJumpChain(target, [inner, target]);

      expect(chain.map((p) => p.host).toList(), ['inner.example']);
    });

    test('an empty-string jumpIdentityKey is treated as none', () {
      // fromJson coerces '' to null, but a hand-built profile must not blow up.
      final target = _p('target.example', jump: '');
      expect(resolveJumpChain(target, [target]), isEmpty);
    });

    test('an empty profile list resolves to no jump host', () {
      final target = _p('target.example', jump: _key('bastion.example'));
      expect(resolveJumpChain(target, const <SavedProfile>[]), isEmpty);
    });
  });
}
