// Unit tests for the FGS-outlives-UI re-handshake (#731).
//
// Bug: when the keepalive foreground service OUTLIVES the UI process, a fresh
// app launch builds a not-ready `FlutterForegroundSshGateway`. The keepalive
// controller sees the service "already running" and SKIPS (re)start, so the
// task never re-runs `onStart` and never re-emits `SshTaskReadyEvent`. The
// gateway stays not-ready forever → every `connect` is buffered and never
// flushed → tapping any profile does nothing (no spinner, no error).
//
// Fix under test:
//   1. `sendControl` reaches the transport even when not-ready (hello must NOT
//      get trapped in the not-ready buffer).
//   2. The controller, on "already running", asks the gateway to re-handshake.
//   3. The task re-emits `SshTaskReadyEvent` on receiving `SshUiHelloCommand`.
//   4. End-to-end: hello round-trip flips the fresh gateway to ready and flushes
//      the buffered `connect` exactly once (no double-flush).
//   5. Timeout: a buffered command with no ready → after the timeout the hello
//      is re-sent once, then a visible error is surfaced. Driven by fakeAsync —
//      no real delays.
//
// #539 cold-start flush + #564 reconnect re-buffer behaviours are covered by
// task_bootstrap_test.dart / reconnect tests and must stay green.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mobissh/services/keepalive_task.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';

class _FakeRunningGateway implements KeepaliveGateway {
  _FakeRunningGateway({required this.running});
  bool running;
  bool _initialized = false;
  final List<String> calls = [];

  @override
  bool get isInitialized => _initialized;

  @override
  Future<bool> get isRunningService async => running;

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
    calls.add('start');
    running = true;
    return true;
  }

  @override
  Future<bool> stopService() async {
    calls.add('stop');
    running = false;
    return true;
  }
}

Future<void> _drain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

SshConnectCommand _connect(String sid) => SshConnectCommand(
  sessionId: sid,
  host: 'h',
  port: 22,
  username: 'u',
  authJson: const {'type': 'password', 'password': 'p'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TaskSshGateway.sendControl bypasses the not-ready buffer (#731)', () {
    test('sendControl reaches the transport while _ready=false', () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);
      final received = <Map<String, dynamic>>[];
      pair.taskSide.registerReceiver((d) {
        received.add(Map<String, dynamic>.from(d as Map));
      });

      final ui = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(ui.dispose);

      // Not ready yet. A normal send buffers; a control send must NOT.
      ui.send(_connect('sid').toJson());
      ui.sendControl(const SshUiHelloCommand().toJson());
      await _drain();

      expect(ui.isReady, isFalse);
      expect(
        received.length,
        1,
        reason:
            'only the control hello reaches the transport; the connect '
            'stays buffered',
      );
      expect(received.single['kind'], SshTaskCommandKind.uiHello.name);
    });
  });

  group('KeepaliveController re-handshakes when already running (#731)', () {
    test(
      'already-running + not-ready → onServiceAlreadyRunning fires',
      () async {
        final gateway = _FakeRunningGateway(running: true);
        var rehandshakes = 0;
        final controller = KeepaliveController(
          gateway: gateway,
          onServiceAlreadyRunning: () => rehandshakes++,
        );
        addTearDown(controller.dispose);

        await controller.ensureStarted();
        await _drain();

        expect(
          gateway.calls,
          isNot(contains('start')),
          reason: 'service already running — must not start a second one',
        );
        expect(
          rehandshakes,
          1,
          reason: 'already-running path must request a re-handshake',
        );
      },
    );

    test('service NOT running → starts fresh, no re-handshake', () async {
      final gateway = _FakeRunningGateway(running: false);
      var rehandshakes = 0;
      final controller = KeepaliveController(
        gateway: gateway,
        onServiceAlreadyRunning: () => rehandshakes++,
      );
      addTearDown(controller.dispose);

      await controller.ensureStarted();
      await _drain();

      expect(gateway.calls, contains('start'));
      expect(
        rehandshakes,
        0,
        reason: 'cold start must not go down the re-handshake path',
      );
    });
  });

  group('KeepaliveTaskHandler re-emits ready on uiHello (#731)', () {
    test('onReceiveData(uiHello) → SshTaskReadyEvent back to the UI', () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);
      // Capture everything the task pushes toward the UI.
      final toUi = <Map<String, dynamic>>[];
      pair.uiSide.registerReceiver((d) {
        toUi.add(Map<String, dynamic>.from(d as Map));
      });

      final handler = KeepaliveTaskHandler(
        hostBuilder: (gateway) => _NoopHost(gateway),
        transportForTest: _PairFedTaskTransport(pair.taskSide),
      );
      await handler.onStart(DateTime.now(), TaskStarter.developer);

      handler.onReceiveData(const SshUiHelloCommand().toJson());
      await _drain();

      expect(
        toUi.where((m) => m['kind'] == SshTaskEventKind.ready.name).length,
        1,
        reason: 'uiHello must provoke exactly one ready re-emit',
      );

      await handler.onDestroy(DateTime.now(), false);
    });

    test('uiHello is NOT forwarded as a session command to the host', () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);
      final hostInbound = <Map<String, dynamic>>[];
      final handler = KeepaliveTaskHandler(
        hostBuilder: (gateway) {
          gateway.incoming.listen(hostInbound.add);
          return _NoopHost(gateway);
        },
        transportForTest: _PairFedTaskTransport(pair.taskSide),
      );
      await handler.onStart(DateTime.now(), TaskStarter.developer);

      handler.onReceiveData(const SshUiHelloCommand().toJson());
      await _drain();

      expect(
        hostInbound,
        isEmpty,
        reason: 'uiHello is intercepted before delivery to the host',
      );

      await handler.onDestroy(DateTime.now(), false);
    });
  });

  group('End-to-end: fresh gateway + live task re-handshake (#731)', () {
    test('buffered connect flushes after hello round-trip, exactly once', () async {
      // Topology (service outlived the UI process — fresh, not-ready UI gateway
      // + already-running task):
      //   UI gateway  ── pair.uiSide ──►  (UI→task wire)
      //   task handler ── pair-fed transport ──►  (task→UI wire)
      // The UI→task wire is consumed by the handler's `onReceiveData` (the FFT
      // entry point in prod). We register a receiver on it that BOTH records
      // what the UI sends AND forwards to the handler, exactly as FFT would.
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);

      final ui = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(ui.dispose);

      // Task handler: its task→UI sends flow back through the pair to the UI
      // gateway. _NoopHost ignores inbound session commands.
      final handler = KeepaliveTaskHandler(
        hostBuilder: (gateway) => _NoopHost(gateway),
        transportForTest: _PairFedTaskTransport(pair.taskSide),
      );

      // Record + forward UI→task payloads to the handler's onReceiveData (FFT
      // delivery emulation). Registered AFTER onStart so the pair-fed
      // transport's own deliver registration isn't clobbered — but the handler
      // intercepts uiHello before delivery anyway.
      final toTask = <Map<String, dynamic>>[];
      pair.taskSide.registerReceiver((d) {
        final m = Map<String, dynamic>.from(d as Map);
        toTask.add(m);
        handler.onReceiveData(m);
      });

      await handler.onStart(DateTime.now(), TaskStarter.developer);

      // The fresh UI gateway buffers a connect (not ready yet).
      ui.send(_connect('sid').toJson());
      await _drain();
      expect(ui.isReady, isFalse);
      expect(
        toTask.where((m) => m['kind'] == SshTaskCommandKind.connect.name),
        isEmpty,
        reason: 'connect must be buffered while not-ready',
      );

      // Re-handshake: UI sends hello via sendControl (bypasses the buffer); the
      // pair delivers it to the handler, which re-emits ready back to the UI.
      ui.sendControl(const SshUiHelloCommand().toJson());
      await _drain();
      await _drain();

      // ready re-emit flipped the UI gateway → the buffered connect flushed.
      expect(
        ui.isReady,
        isTrue,
        reason: 'ready re-emit must flip the fresh gateway',
      );
      final connects = toTask.where(
        (m) => m['kind'] == SshTaskCommandKind.connect.name,
      );
      expect(
        connects.length,
        1,
        reason: 'the buffered connect flushes exactly once',
      );

      await handler.onDestroy(DateTime.now(), false);
    });

    test(
      'a SECOND ready (e.g. a real onStart) does not double-flush',
      () async {
        final pair = StubFftTransportPair();
        addTearDown(pair.dispose);
        final toTask = <Map<String, dynamic>>[];
        pair.taskSide.registerReceiver((d) {
          toTask.add(Map<String, dynamic>.from(d as Map));
        });
        final ui = FlutterForegroundSshGateway(transport: pair.uiSide);
        addTearDown(ui.dispose);

        ui.send(_connect('sid').toJson());
        await _drain();

        // First ready flushes the buffer.
        pair.taskSide.send(const SshTaskReadyEvent().toJson());
        await _drain();
        // A second ready (the real onStart firing late) must not re-flush —
        // the buffer is already empty and the gateway is ready.
        pair.taskSide.send(const SshTaskReadyEvent().toJson());
        await _drain();

        final connects = toTask.where(
          (m) => m['kind'] == SshTaskCommandKind.connect.name,
        );
        expect(
          connects.length,
          1,
          reason: 'connect must flush exactly once across two ready signals',
        );
      },
    );
  });

  group('Timeout guard never hangs silently (#731)', () {
    test(
      'no ready after markServiceAlreadyRunning → hello re-sent then error',
      () {
        fakeAsync((async) {
          final pair = StubFftTransportPair();
          final sentToTask = <Map<String, dynamic>>[];
          pair.taskSide.registerReceiver((d) {
            sentToTask.add(Map<String, dynamic>.from(d as Map));
          });
          final ui = FlutterForegroundSshGateway(
            transport: pair.uiSide,
            rehandshakeTimeout: const Duration(seconds: 3),
          );

          final errors = <Map<String, dynamic>>[];
          ui.incoming
              .where((m) => m['kind'] == SshTaskEventKind.error.name)
              .listen(errors.add);

          // Buffer a connect, then mark the service already-running (arms the
          // timeout). No ready ever arrives.
          ui.send(_connect('sid').toJson());
          ui.markServiceAlreadyRunning();
          async.flushMicrotasks();

          // Before the first window elapses: no hello re-send, no error.
          async.elapse(const Duration(seconds: 2));
          expect(sentToTask.where((m) => m['kind'] == 'uiHello'), isEmpty);
          expect(errors, isEmpty);

          // First window elapses → hello re-sent once.
          async.elapse(const Duration(seconds: 2));
          expect(
            sentToTask.where((m) => m['kind'] == 'uiHello').length,
            1,
            reason: 'first timeout re-sends the hello once',
          );
          expect(
            errors,
            isEmpty,
            reason: 'still patient after the first window',
          );

          // Second window elapses with still no ready → visible error surfaced,
          // scoped to the buffered session.
          async.elapse(const Duration(seconds: 4));
          expect(
            errors.length,
            1,
            reason: 'second timeout surfaces a visible error',
          );
          expect(errors.single['sessionId'], 'sid');

          ui.dispose();
          pair.dispose();
        });
      },
    );

    test(
      'ready before the timeout cancels the guard (no error, no re-hello)',
      () {
        fakeAsync((async) {
          final pair = StubFftTransportPair();
          final sentToTask = <Map<String, dynamic>>[];
          pair.taskSide.registerReceiver((d) {
            sentToTask.add(Map<String, dynamic>.from(d as Map));
          });
          final ui = FlutterForegroundSshGateway(
            transport: pair.uiSide,
            rehandshakeTimeout: const Duration(seconds: 3),
          );
          final errors = <Map<String, dynamic>>[];
          ui.incoming
              .where((m) => m['kind'] == SshTaskEventKind.error.name)
              .listen(errors.add);

          ui.send(_connect('sid').toJson());
          ui.markServiceAlreadyRunning();
          async.flushMicrotasks();

          // Ready arrives well within the window.
          async.elapse(const Duration(seconds: 1));
          pair.taskSide.send(const SshTaskReadyEvent().toJson());
          async.flushMicrotasks();

          // Let both windows pass — nothing should fire.
          async.elapse(const Duration(seconds: 10));
          expect(sentToTask.where((m) => m['kind'] == 'uiHello'), isEmpty);
          expect(errors, isEmpty);
          expect(ui.isReady, isTrue);

          ui.dispose();
          pair.dispose();
        });
      },
    );
  });
}

/// Test helper — a [TaskSideFftTransport] fed by a [StubFftTransport] pair side
/// instead of FFT's `onReceiveData`. Mirrors the helper in
/// task_isolate_handover_test.dart.
class _PairFedTaskTransport extends TaskSideFftTransport {
  _PairFedTaskTransport(this._pairSide);
  final StubFftTransport _pairSide;

  @override
  void send(Object payload) => _pairSide.send(payload);
}

/// A no-op host that ignores all inbound payloads (no SSH). Lets the handler
/// route payloads without a real SessionHost.
class _NoopHost implements SessionHost {
  _NoopHost(this._gateway) {
    _gateway.incoming.listen((_) {});
  }
  final TaskSshGateway _gateway;

  @override
  void noSuchMethod(Invocation invocation) {}
}
