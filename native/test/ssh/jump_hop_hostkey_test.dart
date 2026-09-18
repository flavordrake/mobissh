// A5 + A6 — per-hop host-key verification and named hop failures (#1183,
// spec docs/jump-host.md R8, R9, R10, R11).
//
// R9: EVERY hop's key is verified against the same [HostKeyStore], keyed by
// THAT hop's host:port. Skipping this makes the bastion the weak link — an
// attacker who owns the bastion owns every session that rides it.
//
// R10: the prompt must NAME the host it is asking about. Approving a
// fingerprint without knowing whose it is is not a security decision.
//
// #1108 parity: a CHANGED hop key fails CLOSED with no prompt, exactly like a
// changed target key. The hop path must not reintroduce the fail-open hole.
//
// The seam under test is [SshSessionController.verifyHopHostKey] — the public
// promotion of the existing verify path, handed to the HOP's SSHClient as its
// `onVerifyHostKey` so a hop prompt surfaces in the TARGET session's UI (D3:
// a jump is transport, not a second session).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/ssh/jump_host.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/storage/profiles_store.dart';

const _bastion = SshConnectParams(
  host: 'bastion.example',
  port: 2222,
  username: 'jumpuser',
  auth: SshAuth.password('p'),
);

final _fingerprint = Uint8List.fromList(<int>[0xDE, 0xAD]);
const _fingerprintHex = 'dead';

void main() {
  group('A5 — unknown hop key prompts and NAMES the hop (R9, R10)', () {
    test('an unknown BASTION key raises awaitingHostKey for the BASTION', () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      // ignore: unawaited_futures
      controller.verifyHopHostKey(_bastion, 'ssh-ed25519', _fingerprint);
      await Future<void>.delayed(Duration.zero);

      expect(controller.data.state, SshSessionState.awaitingHostKey);
      final pending = controller.data.pendingHostKey;
      expect(pending, isNotNull);
      expect(
        pending!.host,
        'bastion.example',
        reason: 'R10 — the prompt names the HOP, never the target it fronts',
      );
      expect(pending.port, 2222);
      expect(pending.fingerprint, _fingerprintHex);

      controller.rejectHostKey();
    });

    test('accepting the hop prompt trusts it under the HOP host:port (R9)', () async {
      final backend = InMemoryHostKeyBackend();
      final store = HostKeyStore(backend: backend);
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      final verify = controller.verifyHopHostKey(
        _bastion,
        'ssh-ed25519',
        _fingerprint,
      );
      await Future<void>.delayed(Duration.zero);
      controller.acceptHostKey();

      expect(await verify, isTrue);
      expect(
        store.trustedFingerprint('bastion.example', 2222),
        _fingerprintHex,
        reason: 'trust is keyed by the HOP host:port, not the target',
      );
    });

    test('a hop already trusted proceeds with NO prompt', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend(<String, String>{
          'bastion.example:2222': _fingerprintHex,
        }),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);
      final seen = <SshSessionState>[];
      final sub = controller.stream.listen((d) => seen.add(d.state));
      addTearDown(sub.cancel);

      final ok = await controller.verifyHopHostKey(
        _bastion,
        'ssh-ed25519',
        _fingerprint,
      );

      expect(ok, isTrue);
      expect(seen, isNot(contains(SshSessionState.awaitingHostKey)));
    });
  });

  group('A5 — rejecting a hop key fails the WHOLE connect closed (R9)', () {
    test('reject resolves the hop verify false and fails the session', () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      final verify = controller.verifyHopHostKey(
        _bastion,
        'ssh-ed25519',
        _fingerprint,
      );
      await Future<void>.delayed(Duration.zero);
      controller.rejectHostKey();

      expect(
        await verify,
        isFalse,
        reason: 'a false verify aborts the hop handshake, which aborts the chain',
      );
      expect(controller.data.state, SshSessionState.failed);
      expect(
        controller.data.error,
        contains('bastion.example'),
        reason: 'R10/R11 — the failure must say WHICH host was rejected, or it '
            'reads as if the target refused',
      );
      expect(
        store.trustedFingerprint('bastion.example', 2222),
        isNull,
        reason: 'a rejected key is never persisted',
      );
    });
  });

  group('A5 — a CHANGED hop key fails closed without prompting (#1108)', () {
    test('mismatch → failed, NO awaitingHostKey, stored key preserved', () async {
      final backend = InMemoryHostKeyBackend(<String, String>{
        'bastion.example:2222': 'aabb',
      });
      final store = HostKeyStore(backend: backend);
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);
      final seen = <SshSessionState>[];
      final sub = controller.stream.listen((d) => seen.add(d.state));
      addTearDown(sub.cancel);

      final ok = await controller.verifyHopHostKey(
        _bastion,
        'ssh-ed25519',
        _fingerprint,
      );

      expect(ok, isFalse);
      expect(
        seen,
        isNot(contains(SshSessionState.awaitingHostKey)),
        reason: '#1108 parity — a changed key must never reach a trust prompt',
      );
      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, contains('HOST KEY CHANGED'));
      expect(controller.data.error, contains('bastion.example'));
      expect(
        store.trustedFingerprint('bastion.example', 2222),
        'aabb',
        reason: 'the stored fingerprint is the MITM evidence — never overwritten',
      );
    });

    test('an unreadable trust store refuses the hop (fail closed)', () async {
      final store = HostKeyStore(backend: _BrokenBackend());
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      final ok = await controller.verifyHopHostKey(
        _bastion,
        'ssh-ed25519',
        _fingerprint,
      );

      expect(ok, isFalse);
      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, contains('bastion.example'));
    });
  });

  group('A6 — a hop with a missing secret fails closed, named (R8)', () {
    SavedProfile hop({String? authType, String? vaultId, String? keyVaultId}) =>
        SavedProfile(
          title: 'Bastion',
          host: 'bastion.example',
          port: 2222,
          username: 'jumpuser',
          authType: authType,
          vaultId: vaultId,
          keyVaultId: keyVaultId,
        );

    test('no stored credentials at all → JumpHopError naming the hop', () {
      expect(
        () => resolveJumpHopAuth(hop(authType: 'password'), ProfileCredentials()),
        throwsA(
          isA<JumpHopError>().having(
            (e) => e.toString(),
            'names the hop',
            contains('bastion.example'),
          ),
        ),
      );
    });

    test('a key-auth hop with only a password stored fails closed', () {
      // R8 forbids credential reuse across hops AND across auth kinds — a key
      // profile must not quietly fall back to some other secret.
      expect(
        () => resolveJumpHopAuth(
          hop(authType: 'key'),
          ProfileCredentials(password: 'hunter2'),
        ),
        throwsA(isA<JumpHopError>()),
      );
    });

    test('a password hop with a stored password resolves to SshAuthPassword', () {
      final auth = resolveJumpHopAuth(
        hop(authType: 'password'),
        ProfileCredentials(password: 'hunter2'),
      );
      expect(auth, isA<SshAuthPassword>());
      expect((auth as SshAuthPassword).password, 'hunter2');
    });

    test('a key hop with a stored PEM resolves to SshAuthKey with passphrase', () {
      final auth = resolveJumpHopAuth(
        hop(authType: 'key'),
        ProfileCredentials(
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n',
          passphrase: 'pp',
        ),
      );
      expect(auth, isA<SshAuthKey>());
      expect((auth as SshAuthKey).passphrase, 'pp');
    });

    test('an empty stored password is treated as missing (fail closed)', () {
      expect(
        () => resolveJumpHopAuth(
          hop(authType: 'password'),
          ProfileCredentials(password: ''),
        ),
        throwsA(isA<JumpHopError>()),
      );
    });

    test('jumpHopParams carries the HOP identity, not the target', () {
      final params = jumpHopParams(
        hop(authType: 'password'),
        const SshAuth.password('p'),
      );
      expect(params.host, 'bastion.example');
      expect(params.port, 2222);
      expect(params.username, 'jumpuser');
      expect(params.hostKey, 'bastion.example:2222');
    });
  });
}

/// A backend whose load THROWS — models corrupt/unavailable trust storage.
class _BrokenBackend implements HostKeyBackend {
  @override
  Future<Map<String, String>> loadAll() async =>
      throw const FormatException('corrupt');

  @override
  Future<void> saveAll(Map<String, String> map) async {}
}
