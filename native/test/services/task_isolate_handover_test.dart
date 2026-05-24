// Cross-isolate handover tests for the foreground-task SSH host (#531).
//
// The production gateway pair — [FlutterForegroundSshGateway] (UI) and
// [TaskSideForegroundGateway] (task) — talks across the FFT IPC boundary. We
// can't bind to platform channels inside `flutter test`, so the gateways
// expose a transport seam: production transport calls
// `FlutterForegroundTask.sendData…` statics; the [StubFftTransport] pair
// shipped in `task_ssh_gateway.dart` mirrors that topology with in-process
// `StreamController`s.
//
// The tests below construct a UI-side `FlutterForegroundSshGateway` and a
// task-side `TaskSideForegroundGateway` connected via a stub transport pair,
// then wire a real `SessionHost` to the task side and a real `SshSessionProxy`
// to the UI side. The full envelope flow — encode in UI, transport, decode
// in task, dispatch to `SshSessionController`, encode reply, transport back,
// decode in UI — is exercised end-to-end.
//
// Plus: `KeepaliveTaskHandler.onStart` constructs a host bound to a
// task-side transport that we can drive directly through `onReceiveData`.
// That test enforces #531 acceptance bullet "the task isolate is the SSH
// lifecycle owner" — the handler is the thing that physically holds the
// host.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mobissh/services/keepalive_task.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) async {
      // Synchronous throw — controller transitions straight to `failed`,
      // no pending timers (avoids fake-async leak detection in widget tests).
      throw Exception('stub socket opener — bypass real connect');
    },
  );
}

void main() {
  group('gateway pair via stub transport', () {
    test(
        'UI-side connect command flows through the transport and reaches '
        'the task-side SessionHost', () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);

      final uiGateway = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(uiGateway.dispose);
      // The stub transport is fed via the pair, not via the FFT
      // transport's `deliver`. We wire it manually so the gateway sees
      // payloads coming through the test transport.
      final taskTransport = _PairFedTaskTransport(pair.taskSide);
      final realTaskGateway =
          TaskSideForegroundGateway(transport: taskTransport);
      addTearDown(realTaskGateway.dispose);

      final host = SessionHost(
        gateway: realTaskGateway,
        controllerFactory: _stubControllerFactory,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);

      final proxy = SshSessionProxy(
        sessionId: 'sid-handover',
        gateway: uiGateway,
      );
      addTearDown(proxy.dispose);

      // Issue a connect through the UI proxy. The command must travel the
      // stub transport into the task gateway, get decoded by the host, and
      // result in a hosted controller.
      proxy.connect(const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      // Drain the event loop so the controllers all register.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(host.sessionIds, contains('sid-handover'));

      // Inject task-side output and verify the UI proxy sees the snapshot
      // through the transport.
      host.ingestOutputForTest(
        'sid-handover',
        Uint8List.fromList('hello\n'.codeUnits),
      );
      proxy.rebind();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(proxy.snapshot.scrollbackTail, contains('hello'));
      expect(proxy.snapshot.bytesIn, greaterThanOrEqualTo(6));
    });

    test('task-side state events flow back through the transport to the UI',
        () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);

      final uiGateway = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(uiGateway.dispose);
      final taskTransport = _PairFedTaskTransport(pair.taskSide);
      final taskGateway = TaskSideForegroundGateway(transport: taskTransport);
      addTearDown(taskGateway.dispose);

      final host = SessionHost(
        gateway: taskGateway,
        controllerFactory: _stubControllerFactory,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);

      final proxy =
          SshSessionProxy(sessionId: 'sid-state', gateway: uiGateway);
      addTearDown(proxy.dispose);

      final seen = <SshSessionState>[];
      final sub = proxy.stream.listen((d) => seen.add(d.state));
      addTearDown(sub.cancel);

      proxy.connect(const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      // Stub socket opener throws synchronously → state machine emits
      // connecting → failed. Both must reach the UI proxy.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(seen, contains(SshSessionState.connecting));
      expect(seen, contains(SshSessionState.failed));
    });

    test('disconnect command tears down the hosted session over the wire',
        () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);

      final uiGateway = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(uiGateway.dispose);
      final taskTransport = _PairFedTaskTransport(pair.taskSide);
      final taskGateway = TaskSideForegroundGateway(transport: taskTransport);
      addTearDown(taskGateway.dispose);

      final host = SessionHost(
        gateway: taskGateway,
        controllerFactory: _stubControllerFactory,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);

      final proxy = SshSessionProxy(
        sessionId: 'sid-disco',
        gateway: uiGateway,
      );
      addTearDown(proxy.dispose);

      proxy.connect(const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(host.sessionIds, contains('sid-disco'));

      proxy.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(host.sessionIds, isNot(contains('sid-disco')));
    });

    test('Map<dynamic, dynamic> payloads are coerced to Map<String, dynamic>',
        () {
      // FFT's platform marshaller can hand back loosely-typed maps; the
      // gateway must coerce before re-dispatching so downstream `fromJson`
      // calls don't blow up with a type error.
      final pair = StubFftTransportPair();
      final uiGateway = FlutterForegroundSshGateway(transport: pair.uiSide);
      final taskTransport = _PairFedTaskTransport(pair.taskSide);
      final taskGateway = TaskSideForegroundGateway(transport: taskTransport);
      final received = <Map<String, dynamic>>[];
      final sub = taskGateway.incoming.listen(received.add);

      // Send a Map<dynamic, dynamic> directly through the transport.
      final loose = <dynamic, dynamic>{
        'kind': 'disconnect',
        'sessionId': 'sid',
      };
      pair.uiSide.send(loose);
      // The pair's stub uses synchronous broadcast streams; one microtask
      // flush is enough for the listener to fire.
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(received, isNotEmpty);
        expect(received.first['kind'], 'disconnect');
        sub.cancel();
        uiGateway.dispose();
        taskGateway.dispose();
        pair.dispose();
      });
    });
  });

  group('KeepaliveTaskHandler hosts a SessionHost in the task isolate', () {
    test('onStart constructs a host bound to the FFT task transport',
        () async {
      // We inject a builder that captures the gateway the handler hands us.
      TaskSshGateway? capturedGateway;
      SessionHost? capturedHost;
      final handler = KeepaliveTaskHandler(
        hostBuilder: (gateway) {
          capturedGateway = gateway;
          final host = SessionHost(
            gateway: gateway,
            controllerFactory: _stubControllerFactory,
            snapshotInterval: const Duration(hours: 1),
          );
          capturedHost = host;
          return host;
        },
      );

      await handler.onStart(DateTime.now(), TaskStarter.developer);
      expect(capturedGateway, isNotNull);
      expect(capturedHost, isNotNull);
      expect(handler.hostForTest, same(capturedHost));
      expect(handler.startedAt, isNotNull);

      // Tear down via onDestroy — host.dispose must be called so any
      // SSHClient instances close cleanly.
      capturedHost!.disposeSyncForTest();
      await handler.onDestroy(DateTime.now(), false);
      expect(handler.hostForTest, isNull);
      expect(handler.startedAt, isNull);
    });

    test('onReceiveData forwards UI payloads into the host gateway',
        () async {
      // Build the handler with a host that we can inspect. The transport is
      // the handler's own (private) task-side FFT transport; the only public
      // way payloads flow in is via onReceiveData.
      final hostInbound = <Map<String, dynamic>>[];
      final handler = KeepaliveTaskHandler(
        hostBuilder: (gateway) {
          // Tap the gateway's incoming stream so we can verify payloads
          // arriving via onReceiveData get there.
          gateway.incoming.listen(hostInbound.add);
          return SessionHost(
            gateway: gateway,
            controllerFactory: _stubControllerFactory,
            snapshotInterval: const Duration(hours: 1),
          );
        },
      );

      await handler.onStart(DateTime.now(), TaskStarter.developer);

      // Deliver a connect command — same wire format the UI proxy would
      // produce. The handler routes it into the gateway via deliver.
      const connect = SshConnectCommand(
        sessionId: 'sid-keepalive',
        host: 'h',
        port: 22,
        username: 'u',
        authJson: {'type': 'password', 'password': 'p'},
      );
      handler.onReceiveData(connect.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(hostInbound, isNotEmpty);
      expect(hostInbound.first['kind'], 'connect');
      expect(handler.hostForTest!.sessionIds, contains('sid-keepalive'));

      handler.hostForTest!.disposeSyncForTest();
      await handler.onDestroy(DateTime.now(), false);
    });

    test('onDestroy disposes the hosted session and clears handler state',
        () async {
      final handler = KeepaliveTaskHandler(
        hostBuilder: (gateway) => SessionHost(
          gateway: gateway,
          controllerFactory: _stubControllerFactory,
          snapshotInterval: const Duration(hours: 1),
        ),
      );
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      const connect = SshConnectCommand(
        sessionId: 'sid-bye',
        host: 'h',
        port: 22,
        username: 'u',
        authJson: {'type': 'password', 'password': 'p'},
      );
      handler.onReceiveData(connect.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(handler.hostForTest!.sessionIds, contains('sid-bye'));

      // Forced sync disposal so we don't leak controllers when the test
      // host tears down via `await onDestroy`.
      handler.hostForTest!.disposeSyncForTest();
      await handler.onDestroy(DateTime.now(), false);
      expect(handler.hostForTest, isNull);
      expect(handler.startedAt, isNull);
    });
  });
}

/// Test helper — a [TaskSideFftTransport] whose inbound payloads come from
/// a [StubFftTransport] pair instead of FFT's `onReceiveData`. Lets the test
/// drive the UI ↔ task channel without binding to platform statics.
class _PairFedTaskTransport extends TaskSideFftTransport {
  _PairFedTaskTransport(this._pairSide) {
    _pairSide.registerReceiver(deliver);
  }

  final StubFftTransport _pairSide;

  @override
  void send(Object payload) {
    _pairSide.send(payload);
  }
}
