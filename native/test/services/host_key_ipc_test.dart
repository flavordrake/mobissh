// Host-key trust-on-first-use over IPC (#536).
//
// After #533 the verify callback runs task-side. These tests prove the IPC
// bridge restores the trust prompt for new hosts:
//   task-side untrusted key  → SshHostKeyChallengeEvent reaches the UI proxy
//   → proxy.pendingHostKey populated
//   → acceptHostKey()/rejectHostKey() sends SshHostKeyDecisionCommand
//   → task-side controller's verify Completer resolves
//   → HostKeyStore gains (accept) / stays empty (reject).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

void main() {
  group('host-key envelope round-trip', () {
    test('SshHostKeyChallengeEvent preserves all fields', () {
      const ev = SshHostKeyChallengeEvent(
        sessionId: 'sid',
        host: 'example.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: 'abc123',
      );
      final restored =
          SshTaskEvent.fromJson(ev.toJson()) as SshHostKeyChallengeEvent;
      expect(restored.sessionId, 'sid');
      expect(restored.host, 'example.com');
      expect(restored.port, 2222);
      expect(restored.keyType, 'ssh-ed25519');
      expect(restored.fingerprint, 'abc123');
    });

    test('SshHostKeyDecisionCommand preserves accepted flag', () {
      for (final accepted in [true, false]) {
        final cmd = SshHostKeyDecisionCommand(
          sessionId: 'sid',
          accepted: accepted,
        );
        final restored =
            SshTaskCommand.fromJson(cmd.toJson()) as SshHostKeyDecisionCommand;
        expect(restored.sessionId, 'sid');
        expect(restored.accepted, accepted);
      }
    });
  });

  group('host-key IPC round-trip via InMemoryGatewayPair', () {
    /// Controllers produced by the factory, in creation order, so the test can
    /// reach into the one a given session is bound to.
    late List<SshSessionController> created;
    late List<HostKeyStore> stores;

    SshSessionController makeController() {
      // In-memory backend: no platform channel in flutter_test, and each
      // controller gets its own isolated trust store (#565).
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      // socketOpener never resolves so connect() parks in `connecting` and we
      // drive the host-key verify path directly via verifyHostKeyForTest —
      // no real TCP attempt that would race the controller to `failed`.
      final c = SshSessionController(
        hostKeyStore: store,
        socketOpener: (host, port, {timeout}) {
          return Future.delayed(const Duration(days: 1), () {
            throw Exception('socketOpener not used in host-key IPC tests');
          });
        },
      );
      created.add(c);
      stores.add(store);
      return c;
    }

    setUp(() {
      created = [];
      stores = [];
    });

    Uint8List fp(List<int> bytes) => Uint8List.fromList(bytes);

    test('accept: challenge surfaces, decision trusts the key', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: makeController,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);
      final proxy = SshSessionProxy(sessionId: 'sid-a', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      // Spin up the hosted controller (its connect socketOpener never resolves,
      // so we drive the verify path directly via the test seam below).
      proxy.connect(
        const SshConnectParams(
          host: 'newhost',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(created, hasLength(1));
      final controller = created.first;
      final store = stores.first;

      // Drive an untrusted host-key verification on the task side.
      final verifyFuture = controller.verifyHostKeyForTest(
        const SshConnectParams(
          host: 'newhost',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
        'ssh-ed25519',
        fp([0xDE, 0xAD, 0xBE, 0xEF]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The UI proxy must now see a pending host-key prompt.
      expect(proxy.data.pendingHostKey, isNotNull);
      expect(proxy.data.pendingHostKey!.host, 'newhost');
      expect(proxy.data.pendingHostKey!.port, 22);
      expect(proxy.data.pendingHostKey!.keyType, 'ssh-ed25519');
      expect(proxy.data.pendingHostKey!.fingerprint, 'deadbeef');
      expect(proxy.data.state, SshSessionState.awaitingHostKey);

      // User accepts → decision crosses the wire → controller resolves true.
      proxy.acceptHostKey();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await verifyFuture, isTrue);
      expect(store.isTrusted('newhost', 22, 'deadbeef'), isTrue);
      // Prompt cleared on the UI side.
      expect(proxy.data.pendingHostKey, isNull);
    });

    test('reject: decision aborts and does not trust', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: makeController,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);
      final proxy = SshSessionProxy(sessionId: 'sid-r', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      proxy.connect(
        const SshConnectParams(
          host: 'rejhost',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final controller = created.first;
      final store = stores.first;

      final verifyFuture = controller.verifyHostKeyForTest(
        const SshConnectParams(
          host: 'rejhost',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
        'ssh-rsa',
        fp([0x01, 0x02, 0x03]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(proxy.data.pendingHostKey, isNotNull);

      proxy.rejectHostKey();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await verifyFuture, isFalse);
      expect(store.length, 0);
      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, contains('rejected'));
    });

    test('multi-session: challenges are independent', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: makeController,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);
      final proxyA = SshSessionProxy(sessionId: 'sid-1', gateway: pair.uiSide);
      final proxyB = SshSessionProxy(sessionId: 'sid-2', gateway: pair.uiSide);
      addTearDown(proxyA.dispose);
      addTearDown(proxyB.dispose);

      const paramsA = SshConnectParams(
        host: 'hostA',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      );
      const paramsB = SshConnectParams(
        host: 'hostB',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      );
      proxyA.connect(paramsA);
      proxyB.connect(paramsB);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(created, hasLength(2));

      // created order follows connect order: A (sid-1) then B (sid-2).
      final ctrlA = created[0];
      final ctrlB = created[1];
      final storeA = stores[0];
      final storeB = stores[1];

      final fA = ctrlA.verifyHostKeyForTest(
        paramsA,
        'ssh-ed25519',
        fp([0xAA, 0xAA]),
      );
      final fB = ctrlB.verifyHostKeyForTest(
        paramsB,
        'ssh-ed25519',
        fp([0xBB, 0xBB]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(proxyA.data.pendingHostKey!.fingerprint, 'aaaa');
      expect(proxyB.data.pendingHostKey!.fingerprint, 'bbbb');

      // Accept only session 1; session 2 must remain unanswered.
      proxyA.acceptHostKey();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await fA, isTrue);
      expect(storeA.isTrusted('hostA', 22, 'aaaa'), isTrue);
      expect(proxyA.data.pendingHostKey, isNull);

      // Session 2's verify Completer is still pending and its store empty.
      expect(storeB.length, 0);
      expect(proxyB.data.pendingHostKey, isNotNull);
      var bResolved = false;
      // ignore: unawaited_futures
      fB.then((_) => bResolved = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bResolved, isFalse);

      // Now answer B so the pending Completer doesn't leak past teardown.
      proxyB.rejectHostKey();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await fB, isFalse);
    });
  });
}
