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
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    calls.add('update:$notificationText');
  }

  @override
  Future<bool> stopService() async {
    calls.add('stop');
    _running = false;
    return true;
  }
}

/// Gateway whose `isRunningService` reads can be suspended on a [Completer]
/// (#1021). Lets a test hold `_stopIfRunning()` mid-await while another
/// session's transition interleaves, reproducing the stale-stop race
/// deterministically instead of relying on microtask ordering.
class GatedFakeKeepaliveGateway extends FakeKeepaliveGateway {
  /// When non-null, every `isRunningService` read suspends until completed.
  Completer<void>? holdIsRunning;

  @override
  Future<bool> get isRunningService async {
    final gate = holdIsRunning;
    if (gate != null) await gate.future;
    return _running;
  }

  void releaseGate() {
    final gate = holdIsRunning;
    holdIsRunning = null;
    gate?.complete();
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

  void emit(SshSessionState state, {String? host, String? username}) {
    _data = _data.copyWith(state: state, host: host, username: username);
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

  group('KeepaliveController', () {
    test('starts service when session enters connected', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connecting);
      await _drain();
      // #1018: `connecting` now holds the service (hold-unless-terminal), so
      // the count path starts it here already. Pre-#1018 the start waited for
      // `connected` (production relied on ensureStarted #539 instead); the
      // dip-free count is what keeps a mid-reconnect stop from firing.
      expect(gateway.calls.first, 'init');
      expect(gateway.calls.any((c) => c.startsWith('start:')), isTrue);
      expect(controller.connectedCount, 1);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1,
          reason: 'no double-count when connecting reaches connected');

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
      final controller = KeepaliveController(
        gateway: gateway,
        enabled: false,
      );
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

    test('toggle back on starts service if a session is still connected',
        () async {
      final gateway = FakeKeepaliveGateway();
      final controller =
          KeepaliveController(gateway: gateway, enabled: false);
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
    });

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
      expect(await gateway.isRunningService, isTrue,
          reason: 'service must stay running across transient reconnects');
      expect(controller.connectedCount, 1);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1,
          reason: 'no double-count when transitioning back to connected');

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

    // #1018: a single-session soft drop must not transiently release the
    // service. The real reconnect path re-emits connecting/authenticating via
    // connect(), so the hold must survive the FULL cycle — any 1→0 dip
    // schedules an unawaited stop that races (and beats) the revive.
    test(
        'single-session soft drop → full reconnect cycle never stops the '
        'service (#1018)', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      // connected → softDisconnected → reconnecting → (idle is set silently,
      // not emitted) → connecting → authenticating → connected, exactly as
      // SshSessionController emits during an auto-reconnect.
      session.emit(SshSessionState.softDisconnected);
      session.emit(SshSessionState.reconnecting);
      await _drain();
      session.emit(SshSessionState.connecting);
      session.emit(SshSessionState.authenticating);
      await _drain();
      session.emit(SshSessionState.connected);
      await _drain();

      expect(gateway.calls.where((c) => c == 'stop'), isEmpty,
          reason: 'no stop may be scheduled at ANY point mid-reconnect — an '
              'unawaited stop lands after the revive and kills the task '
              'isolate\n${gateway.calls}');
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1,
          reason: 'count must not dip or double across the cycle');

      await controller.dispose();
      await session.dispose();
    });

    test('user disconnect after a soft drop still stops the service (#1018)',
        () async {
      // #986 adjacency: user intent ends in the terminal `disconnected`
      // state — softDisconnected holding must not keep the FGS alive past it.
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected);
      await _drain();
      session.emit(SshSessionState.softDisconnected);
      await _drain();
      expect(await gateway.isRunningService, isTrue,
          reason: 'softDisconnected is reconnect-bound — it holds');

      session.emit(SshSessionState.disconnected);
      await _drain();
      expect(await gateway.isRunningService, isFalse);
      expect(controller.connectedCount, 0);

      await controller.dispose();
      await session.dispose();
    });

    test('multi-session: one soft-dropping session never stops the service '
        '(#1018)', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final a = StubSession();
      final b = StubSession();
      controller.attach(a);
      controller.attach(b);

      a.emit(SshSessionState.connected);
      b.emit(SshSessionState.connected);
      await _drain();
      expect(controller.connectedCount, 2);

      a.emit(SshSessionState.softDisconnected);
      a.emit(SshSessionState.reconnecting);
      await _drain();

      expect(gateway.calls.where((c) => c == 'stop'), isEmpty);
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 2);

      await controller.dispose();
      await a.dispose();
      await b.dispose();
    });
  });

  // #1021: `_stopIfRunning()` must re-check the holder count after its awaits
  // and immediately before the actual `stopService` call. A stop scheduled by
  // A going terminal (count → 0) is STALE if B's connect bumps the count back
  // up before the stop's awaits resolve — landing it anyway kills the FGS
  // (and its task isolate) under B's live session. Complementary to the #1018
  // predicate fix: that keeps the count from dipping mid-lifecycle; this
  // guards the stop PATH itself against a genuine 0→1 in the await gap.
  group('KeepaliveController stale-stop recheck (#1021)', () {
    test('stale stop aborts when a concurrent connect re-holds the service',
        () async {
      final gateway = GatedFakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final a = StubSession();
      final b = StubSession();
      controller.attach(a);
      controller.attach(b);

      a.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1);

      // Suspend all isRunningService reads so the scheduled stop parks
      // mid-await, exactly like a slow platform-channel round trip.
      gateway.holdIsRunning = Completer<void>();
      a.emit(SshSessionState.disconnected); // count 1→0, stop scheduled
      await _drain();

      // B's connect interleaves BEFORE the stop's awaits resolve.
      b.emit(SshSessionState.connecting); // count 0→1
      await _drain();
      expect(controller.connectedCount, 1);

      gateway.releaseGate();
      await _drain();

      expect(gateway.calls.where((c) => c == 'stop'), isEmpty,
          reason: 'the stale stop must abort — landing it kills the FGS under '
              'B\'s live connection\n${gateway.calls}');
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1);

      await controller.dispose();
      await a.dispose();
      await b.dispose();
    });

    test('A terminal alone still stops through the same delayed path',
        () async {
      final gateway = GatedFakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final a = StubSession();
      controller.attach(a);

      a.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      gateway.holdIsRunning = Completer<void>();
      a.emit(SshSessionState.disconnected);
      await _drain();
      gateway.releaseGate();
      await _drain();

      expect(gateway.calls.where((c) => c == 'stop'), hasLength(1),
          reason: 'recheck must not block a legitimate stop\n${gateway.calls}');
      expect(await gateway.isRunningService, isFalse);
      expect(controller.connectedCount, 0);

      await controller.dispose();
      await a.dispose();
    });

    test('double-scheduled stale stops both abort under a concurrent connect',
        () async {
      // The #1020 red baseline showed double-scheduling shapes: a second
      // terminal emit while count==0 re-schedules the stop via the #539
      // leak-guard branch. Both parked stops must abort once B re-holds.
      final gateway = GatedFakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final a = StubSession();
      final b = StubSession();
      controller.attach(a);
      controller.attach(b);

      a.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      gateway.holdIsRunning = Completer<void>();
      a.emit(SshSessionState.disconnected); // count 1→0, stop #1 scheduled
      await _drain();
      a.emit(SshSessionState.disconnected); // count==0 + terminal → stop #2
      await _drain();

      b.emit(SshSessionState.connecting); // count 0→1
      await _drain();

      gateway.releaseGate();
      await _drain();

      expect(gateway.calls.where((c) => c == 'stop'), isEmpty,
          reason: 'BOTH parked stops are stale once B holds the service\n'
              '${gateway.calls}');
      expect(await gateway.isRunningService, isTrue);
      expect(controller.connectedCount, 1);

      await controller.dispose();
      await a.dispose();
      await b.dispose();
    });

    test('user toggle-off stop is unconditional even while sessions hold',
        () async {
      // The recheck exempts the disabled path: `enabled = false` means "drop
      // the service even if sessions are still up" — a count recheck must not
      // veto user intent. (Fast-path variant exists as "toggle off stops a
      // running service"; this one parks the stop mid-await first.)
      final gateway = GatedFakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final a = StubSession();
      controller.attach(a);

      a.emit(SshSessionState.connected);
      await _drain();
      expect(await gateway.isRunningService, isTrue);

      gateway.holdIsRunning = Completer<void>();
      controller.enabled = false; // stop scheduled with count still 1
      await _drain();
      gateway.releaseGate();
      await _drain();

      expect(gateway.calls.where((c) => c == 'stop'), hasLength(1),
          reason: 'user disable stops regardless of holder count\n'
              '${gateway.calls}');
      expect(await gateway.isRunningService, isFalse);

      await controller.dispose();
      await a.dispose();
    });
  });

  group('keepaliveNotificationText mapper (#847)', () {
    test('0 connected → Connecting…', () {
      expect(
        keepaliveNotificationText(connectedCount: 0, anyReconnecting: false),
        'Connecting…',
      );
    });
    test('1 connected → Connected — user@host', () {
      expect(
        keepaliveNotificationText(
          connectedCount: 1,
          anyReconnecting: false,
          singleConnected:
              const KeepaliveSessionInfo(host: 'fd-dev', username: 'mfrazier'),
        ),
        'Connected — mfrazier@fd-dev',
      );
    });
    test('1 connected, host only → Connected — host', () {
      expect(
        keepaliveNotificationText(
          connectedCount: 1,
          anyReconnecting: false,
          singleConnected: const KeepaliveSessionInfo(host: 'fd-dev'),
        ),
        'Connected — fd-dev',
      );
    });
    test('N connected → Connected — N sessions', () {
      expect(
        keepaliveNotificationText(connectedCount: 3, anyReconnecting: false),
        'Connected — 3 sessions',
      );
    });
    test('any reconnecting takes priority → Reconnecting… (N connected)', () {
      expect(
        keepaliveNotificationText(connectedCount: 2, anyReconnecting: true),
        'Reconnecting… (2 connected)',
      );
      // Even with 0 connected, reconnecting reflects it.
      expect(
        keepaliveNotificationText(connectedCount: 0, anyReconnecting: true),
        'Reconnecting… (0 connected)',
      );
    });
    test('NEVER sits on Connecting… once a session is up', () {
      final text = keepaliveNotificationText(
        connectedCount: 1,
        anyReconnecting: false,
        singleConnected: const KeepaliveSessionInfo(host: 'h', username: 'u'),
      );
      expect(text, isNot('Connecting…'));
    });
  });

  group('KeepaliveController FGS text updates (#847)', () {
    test('updates notification to Connected — user@host on connect', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(
        SshSessionState.connected,
        host: 'fd-dev',
        username: 'mfrazier',
      );
      await _drain();

      // The running service no longer sits on "Connecting…".
      expect(
        gateway.calls.any((c) => c == 'update:Connected — mfrazier@fd-dev') ||
            gateway.calls.any((c) => c == 'start:Connected — mfrazier@fd-dev'),
        isTrue,
        reason: 'FGS text must reflect the connected session, not Connecting…\n'
            '${gateway.calls}',
      );
      // It must NOT remain on a Connecting… text after connect.
      expect(gateway.calls.last.contains('Connecting…'), isFalse);

      await controller.dispose();
      await session.dispose();
    });

    test('reflects reconnecting in the FGS text', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final session = StubSession();
      controller.attach(session);

      session.emit(SshSessionState.connected, host: 'h', username: 'u');
      await _drain();
      session.emit(SshSessionState.reconnecting, host: 'h', username: 'u');
      await _drain();

      expect(
        gateway.calls.any((c) => c.startsWith('update:Reconnecting…')),
        isTrue,
        reason: 'reconnect must surface in the FGS text\n${gateway.calls}',
      );

      await controller.dispose();
      await session.dispose();
    });

    test('N connected → Connected — N sessions', () async {
      final gateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: gateway);
      final a = StubSession();
      final b = StubSession();
      controller.attach(a);
      controller.attach(b);

      a.emit(SshSessionState.connected, host: 'h1', username: 'u');
      await _drain();
      b.emit(SshSessionState.connected, host: 'h2', username: 'u');
      await _drain();

      expect(
        gateway.calls.any((c) => c == 'update:Connected — 2 sessions'),
        isTrue,
        reason: 'two connected sessions must read "2 sessions"\n${gateway.calls}',
      );

      await controller.dispose();
      await a.dispose();
      await b.dispose();
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

      final proxy =
          SshSessionProxy(sessionId: 'sid', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      controller.attach(proxy);

      // Push a `connected` state event from the task side.
      pair.taskSide.send(SshStateEvent(
        sessionId: 'sid',
        state: SshSessionState.connected.name,
      ).toJson());
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

      final proxy =
          SshSessionProxy(sessionId: 'sid', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      controller.attach(proxy);

      pair.taskSide.send(SshStateEvent(
        sessionId: 'sid',
        state: SshSessionState.connected.name,
      ).toJson());
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

      final proxy =
          SshSessionProxy(sessionId: 'sid', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      controller.attach(proxy);

      pair.taskSide.send(SshStateEvent(
        sessionId: 'sid',
        state: SshSessionState.connected.name,
      ).toJson());
      await _drain();
      expect(await fakeGateway.isRunningService, isTrue);

      pair.taskSide.send(SshStateEvent(
        sessionId: 'sid',
        state: SshSessionState.reconnecting.name,
      ).toJson());
      await _drain();
      expect(await fakeGateway.isRunningService, isTrue,
          reason: 'service must stay running across transient reconnects');
      expect(controller.connectedCount, 1);

      await controller.dispose();
    });
  });
}
