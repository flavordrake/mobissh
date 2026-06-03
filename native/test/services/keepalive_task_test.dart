// Unit tests for the background keep-alive controller (#512, #533).
//
// We never call the real `FlutterForegroundTask` here — instead the
// `KeepaliveController` is given a `FakeKeepaliveGateway` and we assert that
// start/stop are called in response to SSH session lifecycle changes and the
// user-toggle.
//
// #533: `KeepaliveController.attach` now accepts either an
// `SshSessionController` (legacy) or an `SshSessionProxy` (UI consumer path).
// The proxy-based fixture lives at the bottom of the file.

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/keepalive_task.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

class FakeKeepaliveGateway implements KeepaliveGateway {
  bool _initialized = false;
  bool _running = false;
  final List<String> calls = [];

  @override
  bool get isInitialized => _initialized;

  @override
  Future<bool> get isRunningService async => _running;

  @override
  void init() {
    calls.add('init');
    _initialized = true;
  }

  @override
  Future<bool> startService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    calls.add('start:$notificationText');
    _running = true;
    return true;
  }

  @override
  Future<bool> updateService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    calls.add('update:$notificationText');
    return true;
  }

  @override
  Future<bool> stopService() async {
    calls.add('stop');
    _running = false;
    return true;
  }
}

/// Test double for SshSessionController. We avoid spinning up a real
/// dartssh2 client by emitting [SshSessionData] directly through the
/// public broadcast stream.
class StubSession implements SshSessionController {
  final StreamController<SshSessionData> _ctrl =
      StreamController<SshSessionData>.broadcast();
  SshSessionData _data = const SshSessionData();

  @override
  SshSessionData get data => _data;

  @override
  Stream<SshSessionData> get stream => _ctrl.stream;

  void emit(SshSessionState state) {
    _data = _data.copyWith(state: state);
    _ctrl.add(_data);
  }

  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }

  // Unused members in tests; throw to catch accidental calls.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not stubbed');
}

Future<void> _drain() async {
  // Let the broadcast stream + the controller's async start/stop calls
  // resolve before assertions.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // #709 slice 1: pure count → notification-text mapping.
  group('keepaliveNotificationText', () {
    test('0 connected → minimal handshake text', () {
      expect(keepaliveNotificationText(0), 'Connecting…');
    });

    test('1 connected, no label → singular count form', () {
      expect(keepaliveNotificationText(1), '1 session connected');
    });

    test('1 connected, empty/whitespace label → singular count form', () {
      expect(
        keepaliveNotificationText(1, hostLabel: ''),
        '1 session connected',
      );
      expect(
        keepaliveNotificationText(1, hostLabel: '   '),
        '1 session connected',
      );
    });

    test('1 connected, with label → "Connected — <label>"', () {
      expect(
        keepaliveNotificationText(1, hostLabel: 'me@example.com'),
        'Connected — me@example.com',
      );
    });

    test('1 connected trims surrounding whitespace on the label', () {
      expect(
        keepaliveNotificationText(1, hostLabel: '  me@host  '),
        'Connected — me@host',
      );
    });

    test('N>1 connected → plural count form (label ignored)', () {
      expect(keepaliveNotificationText(2), '2 sessions connected');
      expect(
        keepaliveNotificationText(3, hostLabel: 'me@host'),
        '3 sessions connected',
      );
    });
  });

  // #709 slice 1: the controller drives updateService on count changes while
  // the service stays running, and renders the single-session host label.
  group('KeepaliveController notification updates (#709)', () {
    test(
      'start shows the single-session label when a resolver is set',
      () async {
        final gateway = FakeKeepaliveGateway();
        final controller = KeepaliveController(
          gateway: gateway,
          notificationLabelResolver: () => 'me@host:22',
        );
        final session = StubSession();
        controller.attach(session);

        session.emit(SshSessionState.connected);
        await _drain();
        expect(gateway.calls, contains('start:Connected — me@host:22'));

        await controller.dispose();
        await session.dispose();
      },
    );

    test('second session updates notification to plural count', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(
        gateway: gateway,
        notificationLabelResolver: () => 'me@host:22',
      );
      final s1 = StubSession();
      final s2 = StubSession();
      controller.attach(s1);
      controller.attach(s2);

      s1.emit(SshSessionState.connected);
      await _drain();
      expect(controller.connectedCount, 1);
      expect(gateway.calls, contains('start:Connected — me@host:22'));

      s2.emit(SshSessionState.connected);
      await _drain();
      expect(controller.connectedCount, 2);
      // Service stays running (no second start); count text pushed via update.
      expect(gateway.calls, contains('update:2 sessions connected'));
      expect(
        gateway.calls.where((c) => c.startsWith('start:')).length,
        1,
        reason: 'second session must not re-start the service',
      );

      await controller.dispose();
      await s1.dispose();
      await s2.dispose();
    });

    test('disconnecting one of two pushes a single-session update', () async {
      final gateway = FakeKeepaliveGateway();
      // The UI resolver returns the sole connected session's label; emulate it
      // here with a flag the test flips as it drives the stub session counts.
      var oneConnected = false;
      final controller = KeepaliveController(
        gateway: gateway,
        notificationLabelResolver: () => oneConnected ? 'me@host:22' : null,
      );
      final s1 = StubSession();
      final s2 = StubSession();
      controller.attach(s1);
      controller.attach(s2);

      s1.emit(SshSessionState.connected);
      s2.emit(SshSessionState.connected);
      await _drain();
      expect(controller.connectedCount, 2);

      // One drops → back to a single connected session; the resolver now yields
      // the surviving label, and the controller pushes a silent update.
      oneConnected = true;
      s2.emit(SshSessionState.disconnected);
      await _drain();
      expect(controller.connectedCount, 1);
      expect(gateway.calls, contains('update:Connected — me@host:22'));
      expect(
        await gateway.isRunningService,
        isTrue,
        reason: 'service must stay running while one session remains',
      );

      await controller.dispose();
      await s1.dispose();
      await s2.dispose();
    });

    test('no label resolver → count form on start and update', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final s1 = StubSession();
      final s2 = StubSession();
      controller.attach(s1);
      controller.attach(s2);

      s1.emit(SshSessionState.connected);
      await _drain();
      expect(gateway.calls, contains('start:1 session connected'));

      s2.emit(SshSessionState.connected);
      await _drain();
      expect(gateway.calls, contains('update:2 sessions connected'));

      await controller.dispose();
      await s1.dispose();
      await s2.dispose();
    });
  });

  group('KeepaliveController', () {
    test('starts service when session enters connected', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connecting);
      await _drain();
      expect(
        gateway.calls,
        isEmpty,
        reason: 'no service start while still connecting',
      );

      session.emit(SshSessionState.connected);
      await _drain();
      expect(gateway.calls.first, 'init');
      expect(gateway.calls.any((c) => c.startsWith('start:')), isTrue);
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1);

      await controller.dispose();
      await session.dispose();
    });

    test('stops service when session disconnects', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      session.emit(SshSessionState.disconnected);
      await _drain();
      expect(await gateway.isRunningService, isFalse);
      expect(gateway.calls.last, 'stop');
      expect(controller.connectedCount, 0);

      await controller.dispose();
      await session.dispose();
    });

    test('failed state also stops the service', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      session.emit(SshSessionState.failed);
      await _drain();

      expect(await gateway.isRunningService, isFalse);
      expect(controller.connectedCount, 0);

      await controller.dispose();
      await session.dispose();
    });

    test('does not start service when disabled', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway, enabled: false);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(gateway.calls, isEmpty);
      expect(await gateway.isRunningService, isFalse);

      await controller.dispose();
      await session.dispose();
    });

    test('toggle off stops a running service', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      controller.enabled = false;
      await _drain();
      expect(await gateway.isRunningService, isFalse);

      await controller.dispose();
      await session.dispose();
    });

    test(
      'toggle back on starts service if a session is still connected',
      () async {
        final gateway = FakeKeepaliveGateway();
        final controller = KeepaliveController(
          gateway: gateway,
          enabled: false,
        );
        final session = StubSession();
        controller.attach(session);

        session.emit(SshSessionState.connected);
        await _drain();
        expect(await gateway.isRunningService, isFalse);

        controller.enabled = true;
        await _drain();
        expect(await gateway.isRunningService, isTrue);

        await controller.dispose();
        await session.dispose();
      },
    );

    test('detach decrements connected count and stops if zero', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      await controller.detach(session);
      expect(await gateway.isRunningService, isFalse);
      expect(controller.connectedCount, 0);

      await session.dispose();
      await controller.dispose();
    });

    test('reconnecting state holds the service running (#517)', () async {
      // Background app swap → kernel aborts socket → controller transitions
      // to `reconnecting`. The foreground service must keep running so the
      // Dart isolate isn't frozen mid-retry.
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      session.emit(SshSessionState.reconnecting);
      await _drain();
      expect(
        await gateway.isRunningService,
        isTrue,
        reason: 'service must stay running across transient reconnects',
      );
      expect(controller.connectedCount, 1);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);
      expect(
        controller.connectedCount,
        1,
        reason: 'no double-count when transitioning back to connected',
      );

      await controller.dispose();
      await session.dispose();
    });

    test('failed after reconnecting stops the service', () async {
      // If reconnect exhausts retries we land in `failed` — service goes
      // away (same as the normal connected→failed flow).
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      session.emit(SshSessionState.reconnecting);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      session.emit(SshSessionState.failed);
      await _drain();
      expect(await gateway.isRunningService, isFalse);
      expect(controller.connectedCount, 0);

      await controller.dispose();
      await session.dispose();
    });
  });

  group('KeepaliveTaskHandler', () {
    test('onStart records timestamp, onDestroy clears', () async {
      final handler = KeepaliveTaskHandler();
      expect(handler.startedAt, isNull);

      final t = DateTime.utc(2026, 5, 24);
      await handler.onStart(t, TaskStarter.developer);
      expect(handler.startedAt, t);

      handler.onRepeatEvent(t); // no-op, just don't throw
      await handler.onDestroy(t, false);
      expect(handler.startedAt, isNull);
    });
  });

  group('KeepaliveController (proxy attach — #533)', () {
    test('starts service when proxy emits connected state', () async {
      final fakeGateway = FakeKeepaliveGateway();
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final controller = KeepaliveController(gateway: fakeGateway);

      final proxy = SshSessionProxy(sessionId: 'sid', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      controller.attach(proxy);

      // Push a `connected` state event from the task side.
      pair.taskSide.send(
        SshStateEvent(
          sessionId: 'sid',
          state: SshSessionState.connected.name,
        ).toJson(),
      );
      await _drain();

      expect(fakeGateway.calls.first, 'init');
      expect(fakeGateway.calls.any((c) => c.startsWith('start:')), isTrue);
      expect(await fakeGateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1);

      await controller.dispose();
    });

    test('stops service when proxy emits disconnected', () async {
      final fakeGateway = FakeKeepaliveGateway();
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final controller = KeepaliveController(gateway: fakeGateway);

      final proxy = SshSessionProxy(sessionId: 'sid', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      controller.attach(proxy);

      pair.taskSide.send(
        SshStateEvent(
          sessionId: 'sid',
          state: SshSessionState.connected.name,
        ).toJson(),
      );
      await _drain();
      expect(await fakeGateway.isRunningService, isTrue);

      pair.taskSide.send(SshClosedEvent(sessionId: 'sid').toJson());
      await _drain();
      expect(await fakeGateway.isRunningService, isFalse);
      expect(controller.connectedCount, 0);

      await controller.dispose();
    });

    test('reconnecting state holds the service for proxies', () async {
      final fakeGateway = FakeKeepaliveGateway();
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final controller = KeepaliveController(gateway: fakeGateway);

      final proxy = SshSessionProxy(sessionId: 'sid', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      controller.attach(proxy);

      pair.taskSide.send(
        SshStateEvent(
          sessionId: 'sid',
          state: SshSessionState.connected.name,
        ).toJson(),
      );
      await _drain();
      expect(await fakeGateway.isRunningService, isTrue);

      pair.taskSide.send(
        SshStateEvent(
          sessionId: 'sid',
          state: SshSessionState.reconnecting.name,
        ).toJson(),
      );
      await _drain();
      expect(
        await fakeGateway.isRunningService,
        isTrue,
        reason: 'service must stay running across transient reconnects',
      );
      expect(controller.connectedCount, 1);

      await controller.dispose();
    });
  });
}
