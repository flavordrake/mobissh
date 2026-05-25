// Cross-isolate bootstrap tests (#539).
//
// Proves the two halves of the connect-deadlock fix:
//   1. The UI-side gateway BUFFERS outbound commands sent before the task
//      signals readiness, then flushes them in order once the first inbound
//      payload (the ready event) arrives.
//   2. `SessionsNotifier.addOrActivate` triggers `ensureStarted()` on the
//      keepalive controller for a freshly-created session, so the foreground
//      task is started before the caller dispatches the first connect.
//
// Both tests use the FFT stub transports / fake gateway — no platform
// channels, no real isolate.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/keepalive_task.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Records the `ensureStarted` / start calls in order so the test can assert
/// the service was started before any command was sent.
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
    calls.add('start');
    _running = true;
    return true;
  }

  @override
  Future<bool> stopService() async {
    calls.add('stop');
    _running = false;
    return true;
  }
}

Future<void> _drain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterForegroundSshGateway buffering (#539)', () {
    test('buffers commands sent before ready, flushes in order after ready',
        () async {
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);

      // Capture what the UI side actually pushes toward the task.
      final received = <Map<String, dynamic>>[];
      pair.taskSide.registerReceiver((data) {
        received.add(Map<String, dynamic>.from(data as Map));
      });

      final ui = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(ui.dispose);

      // The task isolate hasn't signalled ready yet. Send three commands in a
      // specific order: connect, input, resize.
      ui.send(SshConnectCommand(
        sessionId: 'sid',
        host: 'h',
        port: 22,
        username: 'u',
        authJson: const {'type': 'password', 'password': 'p'},
      ).toJson());
      ui.send(SshResizeCommand(sessionId: 'sid', cols: 80, rows: 24).toJson());
      await _drain();

      expect(received, isEmpty,
          reason: 'commands must be buffered until the task is ready');

      // Task signals ready (the first inbound payload the UI ever sees).
      pair.taskSide.send(const SshTaskReadyEvent().toJson());
      await _drain();

      expect(received.length, 2,
          reason: 'buffered commands flush once ready arrives');
      expect(received[0]['kind'], SshTaskCommandKind.connect.name);
      expect(received[1]['kind'], SshTaskCommandKind.resize.name,
          reason: 'order must be preserved: connect before resize');

      // After ready, sends pass through immediately.
      ui.send(SshInputCommand(
        sessionId: 'sid',
        bytes: Uint8List.fromList('x'.codeUnits),
      ).toJson());
      await _drain();
      expect(received.length, 3);
      expect(received[2]['kind'], SshTaskCommandKind.input.name);
    });

    test('any inbound payload (not only ready) flushes the buffer', () async {
      // Defensive: even if the first task→UI payload is a state event rather
      // than the ready event, the buffer should flush — the task is clearly
      // alive and receiving.
      final pair = StubFftTransportPair();
      addTearDown(pair.dispose);
      final received = <Map<String, dynamic>>[];
      pair.taskSide.registerReceiver((data) {
        received.add(Map<String, dynamic>.from(data as Map));
      });
      final ui = FlutterForegroundSshGateway(transport: pair.uiSide);
      addTearDown(ui.dispose);

      ui.send(SshConnectCommand(
        sessionId: 'sid',
        host: 'h',
        port: 22,
        username: 'u',
        authJson: const {'type': 'password', 'password': 'p'},
      ).toJson());
      await _drain();
      expect(received, isEmpty);

      pair.taskSide.send(
        SshStateEvent(sessionId: 'sid', state: 'connecting').toJson(),
      );
      await _drain();
      expect(received.length, 1);
      expect(received[0]['kind'], SshTaskCommandKind.connect.name);
    });
  });

  group('addOrActivate ensures service started (#539)', () {
    test('fresh session triggers ensureStarted before returning', () async {
      final fakeGateway = FakeKeepaliveGateway();
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);

      final container = ProviderContainer(overrides: [
        // UI talks to the in-memory pair so no platform channels are touched.
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        // The keepalive controller used by the starter seam uses the fake
        // foreground-task gateway so we can observe startService.
        keepaliveServiceStarterProvider.overrideWith((ref) {
          final controller = KeepaliveController(gateway: fakeGateway);
          ref.onDispose(controller.dispose);
          return controller.ensureStarted;
        }),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      notifier.addOrActivate(const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      await _drain();

      expect(fakeGateway.calls, contains('start'),
          reason: 'addOrActivate must start the foreground service');
      // start happens via ensureStarted → init then start.
      expect(fakeGateway.calls.indexOf('init'),
          lessThan(fakeGateway.calls.indexOf('start')));
    });

    test('ensureStarted is idempotent — no double start', () async {
      final fakeGateway = FakeKeepaliveGateway();
      final controller = KeepaliveController(gateway: fakeGateway);
      addTearDown(controller.dispose);

      await controller.ensureStarted();
      await controller.ensureStarted();
      await _drain();

      expect(fakeGateway.calls.where((c) => c == 'start').length, 1,
          reason: 'second ensureStarted must not start a second service');
    });
  });
}
