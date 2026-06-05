// End-to-end: lifecycle telemetry must reach the UI-isolate feedback bundle
// (#766 chunk 1).
//
// The meta-bug: `clifecycle` lifecycle lines (resume-liveness probe OUTCOME,
// reconnect decisions) are written ONLY in the foreground-task isolate. Its
// `lifecycleLog` ring is a per-isolate static. The feedback bundle is assembled
// in the UI isolate, reading the UI isolate's (separate, EMPTY) copy — so every
// real device report shipped with NO lifecycle log even though the task isolate
// recorded the events.
//
// The fix forwards each lifecycle line across the UI↔task gateway:
//   task: SessionHost arms `lifecycleForwarder` → sends `SshLifecycleEvent`.
//   UI:   FlutterForegroundSshGateway._onData → `recordLifecycleLine`.
//
// These tests prove each link AND the assembled bundle carries the line. They
// use the real production gateways over a StubFftTransport pair (the same seam
// task_isolate_handover_test uses) so the FFT IPC boundary is faithfully
// exercised without binding to platform method channels.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/diagnostics/crash_environment.dart';
import 'package:mobissh/diagnostics/feedback_bundle.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) async {
      throw Exception('stub socket opener — bypass real connect');
    },
  );
}

Future<void> _drain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  setUp(() {
    clearConnectLog();
    lifecycleForwarder = null;
  });
  tearDown(() {
    clearConnectLog();
    lifecycleForwarder = null;
  });

  test(
    'constructing a SessionHost arms the global lifecycle forwarder (prod path)',
    () {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);

      expect(
        lifecycleForwarder,
        isNull,
        reason: 'no host yet → no forwarder',
      );

      final host = SessionHost(gateway: pair.taskSide);
      addTearDown(host.disposeSyncForTest);

      expect(
        lifecycleForwarder,
        isNotNull,
        reason:
            'the host arms the forwarder in its ctor — this is the PROD path, '
            'not a test-only seam (#766)',
      );
    },
  );

  test('disposing the SessionHost detaches its forwarder', () {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final host = SessionHost(gateway: pair.taskSide);
    expect(lifecycleForwarder, isNotNull);

    host.disposeSyncForTest();
    expect(
      lifecycleForwarder,
      isNull,
      reason: 'dispose must detach the forwarder it installed',
    );
  });

  test(
    'a clifecycle on the task side is forwarded as an SshLifecycleEvent over '
    'the task gateway transport',
    () async {
      final taskTransport = _CapturingTaskTransport();
      final taskGateway = TaskSideForegroundGateway(transport: taskTransport);
      addTearDown(taskGateway.dispose);

      final host = SessionHost(
        gateway: taskGateway,
        controllerFactory: _stubControllerFactory,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.disposeSyncForTest);
      // Drop the ctor's SshTaskReadyEvent so only the lifecycle send remains.
      taskTransport.sent.clear();

      // Now a lifecycle event written "in the task isolate".
      clifecycle('task.host', 'resume-liveness: STALE → reconnect');
      await _drain();

      final lifecycleMsgs = taskTransport.sent
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .where((m) => m['kind'] == SshTaskEventKind.lifecycle.name)
          .toList();
      expect(
        lifecycleMsgs,
        isNotEmpty,
        reason: 'the lifecycle line must be forwarded across the boundary',
      );
      expect(lifecycleMsgs.last['line'], contains('STALE → reconnect'));
    },
  );

  test(
    'the UI-side gateway records a forwarded SshLifecycleEvent into the '
    'lifecycle ring the feedback bundle reads',
    () {
      // Drive the UI gateway directly with a forwarded event (bypassing the
      // shared static a clifecycle would also touch in-process), proving the
      // RECEIVE side is what lands the line in the UI ring.
      final transport = _CapturingUiTransport();
      final uiGateway = FlutterForegroundSshGateway(transport: transport);
      addTearDown(uiGateway.dispose);

      expect(lifecycleLogSnapshot(), isEmpty);

      const line = '08:00:00.000 [task.ssh] probeLiveness: ping-failed';
      transport.deliver(
        const SshLifecycleEvent(line: line).toJson(),
      );

      expect(
        lifecycleLogSnapshot(),
        contains(line),
        reason:
            'the UI gateway must record the forwarded line into the UI '
            'isolate lifecycle ring',
      );

      // And the bundle assembled from that ring carries it.
      final bundle = assembleFeedbackBundle(
        info: const CrashEnvironmentInfo(
          appVersion: '1.0.0',
          buildSha: 'deadbee',
          platformVersion: 'Android 14',
          deviceModel: 'Pixel',
        ),
        connectLog: connectLogSnapshot(),
        lifecycleLog: lifecycleLogSnapshot(),
      );
      expect(
        bundle,
        contains('probeLiveness: ping-failed'),
        reason: 'the feedback bundle must now include the lifecycle log (#766)',
      );
    },
  );

  test(
    'a forwarded lifecycle event does NOT flip the gateway to ready or leak '
    'to session consumers',
    () {
      final transport = _CapturingUiTransport();
      final uiGateway = FlutterForegroundSshGateway(transport: transport);
      addTearDown(uiGateway.dispose);

      final incoming = <Map<String, dynamic>>[];
      uiGateway.incoming.listen(incoming.add);

      transport.deliver(
        const SshLifecycleEvent(line: '00:00:00.000 [task.host] x').toJson(),
      );

      expect(
        uiGateway.isReady,
        isFalse,
        reason:
            'telemetry must not be mistaken for the readiness handshake — only '
            'a real task event flips ready',
      );
      expect(
        incoming,
        isEmpty,
        reason: 'lifecycle telemetry is intercepted, never a session event',
      );
    },
  );
}

/// Minimal UI-side FFT transport stub: records nothing outbound, lets the test
/// push inbound payloads via [deliver].
class _CapturingUiTransport implements FftTransport {
  void Function(Object data)? _onData;

  void deliver(Object data) => _onData?.call(data);

  @override
  void send(Object payload) {}

  @override
  void Function() registerReceiver(void Function(Object data) onData) {
    _onData = onData;
    return () => _onData = null;
  }
}

/// Minimal task-side transport stub: records every outbound payload (what the
/// task isolate would push toward the UI) so the test can assert the lifecycle
/// line crossed the boundary. Extends [TaskSideFftTransport] (the concrete type
/// [TaskSideForegroundGateway] requires) and overrides [send] to capture rather
/// than hit FFT statics.
class _CapturingTaskTransport extends TaskSideFftTransport {
  final List<Object> sent = <Object>[];

  @override
  void send(Object payload) => sent.add(payload);
}
