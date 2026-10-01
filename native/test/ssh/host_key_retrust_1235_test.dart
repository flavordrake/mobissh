// #1235: a CHANGED host key must be recoverable through a deliberate,
// two-step re-trust (forget, then accept on the ordinary first-contact prompt).
//
// Before the fix the CHANGED path only produced an error STRING and nothing in
// the app called HostKeyStore.forget, so a legitimately rebuilt host locked the
// owner out until app data was wiped.
//
// These tests pin:
//   - the mismatch crosses IPC STRUCTURED (host, port, key type, stored,
//     offered, jump-hop), not only inside the error text
//   - forget removes ONLY that host:port, and only for the session's own
//     mismatch (a forget naming some other host is refused task-side)
//   - after forget the reconnect lands on the ORDINARY unknown-host prompt
//     (awaitingHostKey) with the offered fingerprint; nothing is trusted yet
//   - when the task isolate was torn down (a failed first connect stops the
//     foreground service), the forget still applies to the NEXT controller
//     built for that session, even though its store has not hydrated yet
//   - a jump-hop mismatch names the hop

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

const _target = SshConnectParams(
  host: 'nv-dev',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

const _bastion = SshConnectParams(
  host: 'bastion.example',
  port: 2222,
  username: 'jumpuser',
  auth: SshAuth.password('p'),
);

// dartssh2 >= 2.18 (#1226) hands onVerifyHostKey the UTF-8 text
// `SHA256:<b64>`, and that text is what gets shown and stored. A CHANGED key is
// therefore SHA256 vs SHA256 (a legacy MD5 entry re-confirms instead).
const _offeredHex = 'SHA256:OffEredKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _offered = Uint8List.fromList(utf8.encode(_offeredHex));
const _storedHex = 'SHA256:StoredKeyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('controller exposes the mismatch STRUCTURED', () {
    test('target mismatch carries host, port, type, stored, offered', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend({'nv-dev:22': _storedHex}),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      final ok = await controller.verifyHostKeyForTest(
        _target,
        'ssh-ed25519',
        _offered,
      );

      expect(ok, isFalse, reason: 'a CHANGED key stays fail-closed');
      expect(controller.data.state, SshSessionState.failed);
      final m = controller.data.hostKeyMismatch;
      expect(m, isNotNull);
      expect(m!.host, 'nv-dev');
      expect(m.port, 22);
      expect(m.keyType, 'ssh-ed25519');
      expect(m.storedFingerprint, _storedHex);
      expect(m.offeredFingerprint, _offeredHex);
      expect(m.jumpHop, isFalse);
    });

    test('a jump-hop mismatch names the HOP and is flagged as a hop', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend({'bastion.example:2222': _storedHex}),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      final ok = await controller.verifyHopHostKey(
        _bastion,
        'ssh-ed25519',
        _offered,
      );

      expect(ok, isFalse);
      final m = controller.data.hostKeyMismatch;
      expect(m, isNotNull);
      expect(m!.host, 'bastion.example');
      expect(m.port, 2222);
      expect(m.jumpHop, isTrue);
    });

    test('a non-mismatch failure carries NO mismatch', () async {
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      final verify = controller.verifyHostKeyForTest(
        _target,
        'ssh-ed25519',
        _offered,
      );
      await Future<void>.delayed(Duration.zero);
      controller.rejectHostKey();
      await verify;

      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.hostKeyMismatch, isNull);
    });
  });

  group('controller forget', () {
    test('forget for the session mismatch removes only that entry', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend({
          'nv-dev:22': _storedHex,
          'other:22': 'cccc',
        }),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);
      await controller.verifyHostKeyForTest(_target, 'ssh-ed25519', _offered);

      expect(controller.forgetMismatchedHostKey('nv-dev', 22), isTrue);

      expect(store.trustedFingerprint('nv-dev', 22), isNull);
      expect(store.trustedFingerprint('other', 22), 'cccc');
      expect(
        controller.data.hostKeyMismatch,
        isNull,
        reason: 'the Review action goes away once the forget happened',
      );
      expect(
        store.trustedFingerprint('nv-dev', 22),
        isNull,
        reason: 'forget never trusts the offered key',
      );
    });

    test('forget naming a host other than the mismatch is refused', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend({
          'nv-dev:22': _storedHex,
          'other:22': 'cccc',
        }),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);
      await controller.verifyHostKeyForTest(_target, 'ssh-ed25519', _offered);

      expect(controller.forgetMismatchedHostKey('other', 22), isFalse);
      expect(store.trustedFingerprint('other', 22), 'cccc');
      expect(store.trustedFingerprint('nv-dev', 22), _storedHex);
    });

    test('forget without a mismatch is refused', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend({'nv-dev:22': _storedHex}),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);

      expect(controller.forgetMismatchedHostKey('nv-dev', 22), isFalse);
      expect(store.trustedFingerprint('nv-dev', 22), _storedHex);
    });

    test('after forget the same key reaches the first-contact prompt', () async {
      final store = HostKeyStore(
        backend: InMemoryHostKeyBackend({'nv-dev:22': _storedHex}),
      );
      await store.ready;
      final controller = SshSessionController(hostKeyStore: store);
      addTearDown(controller.dispose);
      await controller.verifyHostKeyForTest(_target, 'ssh-ed25519', _offered);
      controller.forgetMismatchedHostKey('nv-dev', 22);

      final verify = controller.verifyHostKeyForTest(
        _target,
        'ssh-ed25519',
        _offered,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.data.state, SshSessionState.awaitingHostKey);
      expect(controller.data.pendingHostKey!.fingerprint, _offeredHex);
      expect(store.trustedFingerprint('nv-dev', 22), isNull);
      controller.acceptHostKey();
      expect(await verify, isTrue);
      expect(store.trustedFingerprint('nv-dev', 22), _offeredHex);
    });
  });

  group('HostKeyStore forget before hydration', () {
    test('a forget issued before hydrate completes is not resurrected',
        () async {
      final backend = InMemoryHostKeyBackend({
        'nv-dev:22': _storedHex,
        'other:22': 'cccc',
      });
      final store = HostKeyStore(backend: backend);
      store.forget('nv-dev', 22);
      await store.ready;
      await _settle();

      expect(store.trustedFingerprint('nv-dev', 22), isNull);
      expect(store.trustedFingerprint('other', 22), 'cccc');
      expect(
        await backend.loadAll(),
        {'other:22': 'cccc'},
        reason: 'the removal is persisted and nothing else is lost',
      );
    });
  });

  group('IPC', () {
    test('SshStateEvent round-trips the structured mismatch', () {
      const ev = SshStateEvent(
        sessionId: 'sid',
        state: 'failed',
        error: 'HOST KEY CHANGED',
        hostKeyMismatch: HostKeyMismatch(
          host: 'bastion.example',
          port: 2222,
          keyType: 'ssh-rsa',
          storedFingerprint: _storedHex,
          offeredFingerprint: _offeredHex,
          jumpHop: true,
        ),
      );
      final back = SshTaskEvent.fromJson(ev.toJson()) as SshStateEvent;
      final m = back.hostKeyMismatch!;
      expect(m.host, 'bastion.example');
      expect(m.port, 2222);
      expect(m.keyType, 'ssh-rsa');
      expect(m.storedFingerprint, _storedHex);
      expect(m.offeredFingerprint, _offeredHex);
      expect(m.jumpHop, isTrue);

      const plain = SshStateEvent(sessionId: 'sid', state: 'failed');
      final plainBack = SshTaskEvent.fromJson(plain.toJson()) as SshStateEvent;
      expect(plainBack.hostKeyMismatch, isNull);
    });

    test('SshForgetHostKeyCommand round-trips', () {
      const cmd = SshForgetHostKeyCommand(
        sessionId: 'sid',
        host: 'nv-dev',
        port: 22,
      );
      final back =
          SshTaskCommand.fromJson(cmd.toJson()) as SshForgetHostKeyCommand;
      expect(back.sessionId, 'sid');
      expect(back.host, 'nv-dev');
      expect(back.port, 22);
    });
  });

  group('SessionHost end to end over InMemoryGatewayPair', () {
    late List<SshSessionController> created;
    late List<HostKeyStore> stores;
    late InMemoryHostKeyBackend backend;

    SshSessionController makeController() {
      final store = HostKeyStore(backend: backend);
      final c = SshSessionController(
        hostKeyStore: store,
        // Never resolves: connect() parks in `connecting`; the verify path is
        // driven directly through the test seam.
        socketOpener: (host, port, {timeout}) => Future.delayed(
          const Duration(days: 1),
          () => throw Exception('unused'),
        ),
      );
      created.add(c);
      stores.add(store);
      return c;
    }

    setUp(() {
      created = [];
      stores = [];
      backend = InMemoryHostKeyBackend({
        'nv-dev:22': _storedHex,
        'other:22': 'cccc',
      });
    });

    test('hosted: mismatch reaches the proxy, forget + reconnect prompts',
        () async {
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

      proxy.connect(_target);
      await _settle();
      final controller = created.single;
      await controller.verifyHostKeyForTest(_target, 'ssh-ed25519', _offered);
      await _settle();

      expect(proxy.data.state, SshSessionState.failed);
      final m = proxy.data.hostKeyMismatch;
      expect(m, isNotNull, reason: 'the mismatch crosses IPC structured');
      expect(m!.storedFingerprint, _storedHex);
      expect(m.offeredFingerprint, _offeredHex);

      expect(proxy.forgetHostKey(), isTrue);
      await _settle();
      expect(stores.single.trustedFingerprint('nv-dev', 22), isNull);
      expect(stores.single.trustedFingerprint('other', 22), 'cccc');
      expect(proxy.data.hostKeyMismatch, isNull);

      // The UI's reconnect re-issues a connect; the host routes it to
      // reconnectNow() on the same controller.
      proxy.connect(_target, force: true);
      await _settle();
      expect(proxy.data.state, SshSessionState.reconnecting);

      // The re-dial offers the new key: it gets the ORDINARY prompt.
      final verify = controller.verifyHostKeyForTest(
        _target,
        'ssh-ed25519',
        _offered,
      );
      await _settle();
      expect(proxy.data.state, SshSessionState.awaitingHostKey);
      expect(proxy.data.pendingHostKey!.fingerprint, _offeredHex);
      expect(
        stores.single.trustedFingerprint('nv-dev', 22),
        isNull,
        reason: 'never trusted in one tap',
      );
      proxy.rejectHostKey();
      await _settle();
      expect(await verify, isFalse);
    });

    test('hosted: a forget command for another host is ignored', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: makeController,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);
      final proxy = SshSessionProxy(sessionId: 'sid-b', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      proxy.connect(_target);
      await _settle();
      await created.single.verifyHostKeyForTest(
        _target,
        'ssh-ed25519',
        _offered,
      );
      await _settle();

      pair.uiSide.send(
        const SshForgetHostKeyCommand(
          sessionId: 'sid-b',
          host: 'other',
          port: 22,
        ).toJson(),
      );
      await _settle();

      expect(stores.single.trustedFingerprint('other', 22), 'cccc');
      expect(stores.single.trustedFingerprint('nv-dev', 22), _storedHex);
    });

    test('not hosted: forget applies to the next controller for the session',
        () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: makeController,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);
      final proxy = SshSessionProxy(sessionId: 'sid-c', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      // The isolate was rebuilt: nothing is hosted for sid-c yet.
      pair.uiSide.send(
        const SshForgetHostKeyCommand(
          sessionId: 'sid-c',
          host: 'nv-dev',
          port: 22,
        ).toJson(),
      );
      proxy.connect(_target, force: true);
      await _settle();

      final store = stores.single;
      expect(store.trustedFingerprint('nv-dev', 22), isNull);
      expect(store.trustedFingerprint('other', 22), 'cccc');

      final verify = created.single.verifyHostKeyForTest(
        _target,
        'ssh-ed25519',
        _offered,
      );
      await _settle();
      expect(proxy.data.state, SshSessionState.awaitingHostKey);
      expect(proxy.data.pendingHostKey!.fingerprint, _offeredHex);
      proxy.rejectHostKey();
      await _settle();
      expect(await verify, isFalse);
    });
  });
}
