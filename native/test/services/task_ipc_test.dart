// Wire contract tests for the UI ↔ task IPC envelopes (#524).
//
// Every command and event must round-trip through `toJson` / `fromJson`
// without losing information. The task-side host and UI-side proxy both
// rely on this invariant — if the envelope ever drops a field the proxy's
// cached state diverges from the task's actual state and the user sees
// either stale UI or a disconnect after a swap-resume.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

void main() {
  group('SshTaskCommand round-trip', () {
    test('SshConnectCommand preserves all fields', () {
      final cmd = SshConnectCommand(
        sessionId: 'host:22:user:1',
        host: 'host',
        port: 22,
        username: 'user',
        authJson: SessionHost.encodeAuth(const SshAuth.password('secret')),
        title: 'My host',
        controlMode: true,
      );
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshConnectCommand>());
      restored as SshConnectCommand;
      expect(restored.sessionId, cmd.sessionId);
      expect(restored.host, 'host');
      expect(restored.port, 22);
      expect(restored.username, 'user');
      expect(restored.authJson, cmd.authJson);
      expect(restored.title, 'My host');
      // #911: the control-mode bit crosses the gateway so the task isolate
      // (which owns the shell + the per-isolate `tmuxControlMode` global) enters
      // `tmux -CC`. A UI-isolate flag never reaches the task isolate otherwise.
      expect(restored.controlMode, isTrue);
    });

    test('SshConnectCommand controlMode defaults false + omitted from json', () {
      final cmd = SshConnectCommand(
        sessionId: 'host:22:user:1',
        host: 'host',
        port: 22,
        username: 'user',
        authJson: SessionHost.encodeAuth(const SshAuth.password('secret')),
      );
      expect(cmd.controlMode, isFalse);
      // Omitted when false so the default wire shape is unchanged (the shipped
      // scrape path sends no extra field).
      expect(cmd.toJson().containsKey('controlMode'), isFalse);
      final restored =
          SshTaskCommand.fromJson(cmd.toJson()) as SshConnectCommand;
      expect(restored.controlMode, isFalse);
    });

    test('SshInputCommand preserves binary bytes', () {
      final bytes = Uint8List.fromList([0x00, 0xFF, 0x7F, 0x80, 0x1B, 0x5B]);
      final cmd = SshInputCommand(sessionId: 'sid', bytes: bytes);
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      restored as SshInputCommand;
      expect(restored.bytes, bytes);
    });

    test('SshResizeCommand defaults pixel dims to 0', () {
      final cmd = SshResizeCommand(sessionId: 'sid', cols: 80, rows: 24);
      final json = cmd.toJson();
      final restored = SshTaskCommand.fromJson(json) as SshResizeCommand;
      expect(restored.cols, 80);
      expect(restored.rows, 24);
      expect(restored.pixelWidth, 0);
      expect(restored.pixelHeight, 0);
    });

    test('SshDisconnectCommand round-trips', () {
      const cmd = SshDisconnectCommand(sessionId: 'sid');
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshDisconnectCommand>());
      expect(restored.sessionId, 'sid');
    });

    test('SshUiHelloCommand round-trips (#731)', () {
      const cmd = SshUiHelloCommand();
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshUiHelloCommand>());
      expect(restored.kind, SshTaskCommandKind.uiHello);
      // Task-global: empty sentinel sessionId, mirroring SshTaskReadyEvent.
      expect(restored.sessionId, '');
    });

    test('SshResumeProbeCommand round-trips (#737)', () {
      const cmd = SshResumeProbeCommand(sessionId: 'host:22:user:1');
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshResumeProbeCommand>());
      expect(restored.kind, SshTaskCommandKind.resumeProbe);
      expect(restored.sessionId, 'host:22:user:1');
    });

    test('SshReconnectCommand round-trips (#817)', () {
      const cmd = SshReconnectCommand(sessionId: 'host:22:user:1');
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshReconnectCommand>());
      expect(restored.kind, SshTaskCommandKind.reconnect);
      expect(restored.sessionId, 'host:22:user:1');
    });

    test('SshSetActiveCommand round-trips active flag (#806)', () {
      for (final active in [true, false]) {
        final cmd = SshSetActiveCommand(active: active);
        final restored = SshTaskCommand.fromJson(cmd.toJson());
        expect(restored, isA<SshSetActiveCommand>());
        restored as SshSetActiveCommand;
        expect(restored.kind, SshTaskCommandKind.setActive);
        expect(restored.active, active);
        // Task-global: empty sentinel sessionId (mirrors SshUiHelloCommand).
        expect(restored.sessionId, '');
      }
    });

    test('SshSetActiveCommand round-trips activeSessionId + activeHost (#847)',
        () {
      final cmd = SshSetActiveCommand(
        active: true,
        activeSessionId: 'fd-dev:22:user:1',
        activeHost: 'fd-dev',
      );
      final restored =
          SshTaskCommand.fromJson(cmd.toJson()) as SshSetActiveCommand;
      expect(restored.active, isTrue);
      expect(restored.activeSessionId, 'fd-dev:22:user:1');
      expect(restored.activeHost, 'fd-dev');
    });

    test('SshSetActiveCommand omits null activeHost (back-compat)', () {
      final cmd = SshSetActiveCommand(active: false, activeSessionId: 'x:1:u:1');
      final json = cmd.toJson();
      expect(json.containsKey('activeHost'), isFalse);
      final restored = SshTaskCommand.fromJson(json) as SshSetActiveCommand;
      expect(restored.activeHost, isNull);
    });

    test('SshControlCommand round-trips a multi-token line intact (#911)', () {
      const cmd =
          SshControlCommand(sessionId: 'sid', command: 'select-window -t @1');
      final restored =
          SshTaskCommand.fromJson(cmd.toJson()) as SshControlCommand;
      expect(restored.kind, SshTaskCommandKind.controlCommand);
      expect(restored.command, 'select-window -t @1');
    });

    test('SshTmuxGestureCommand round-trips each gesture (#911)', () {
      for (final g in TmuxWindowGesture.values) {
        final cmd = SshTmuxGestureCommand(
          sessionId: 'sid',
          gesture: g,
          statusCol: 45,
          statusCols: 90,
        );
        final restored =
            SshTaskCommand.fromJson(cmd.toJson()) as SshTmuxGestureCommand;
        expect(restored.kind, SshTaskCommandKind.tmuxGesture);
        expect(restored.gesture, g);
        expect(restored.statusCol, 45);
        expect(restored.statusCols, 90);
      }
    });

    test('unknown kind throws FormatException', () {
      expect(
        () => SshTaskCommand.fromJson({'kind': 'bogus', 'sessionId': 'sid'}),
        throwsFormatException,
      );
    });
  });

  group('SshTaskEvent round-trip', () {
    test('SshSnapshotEvent preserves all metrics', () {
      const ev = SshSnapshotEvent(
        sessionId: 'sid',
        state: 'connected',
        bytesIn: 12345,
        bytesOut: 678,
        lastKeepaliveRttMs: 42,
        reconnectCount: 2,
        lastReconnectAtMs: 1700000000000,
        scrollbackTail: 'last\nfew\nlines\n',
      );
      final restored = SshTaskEvent.fromJson(ev.toJson()) as SshSnapshotEvent;
      expect(restored.bytesIn, 12345);
      expect(restored.bytesOut, 678);
      expect(restored.lastKeepaliveRttMs, 42);
      expect(restored.reconnectCount, 2);
      expect(restored.lastReconnectAtMs, 1700000000000);
      expect(restored.scrollbackTail, 'last\nfew\nlines\n');
      expect(restored.state, 'connected');
    });

    test('SshStateEvent preserves optional fields', () {
      const ev = SshStateEvent(
        sessionId: 'sid',
        state: 'failed',
        error: 'boom',
        host: 'h',
        port: 22,
        username: 'u',
      );
      final restored = SshTaskEvent.fromJson(ev.toJson()) as SshStateEvent;
      expect(restored.state, 'failed');
      expect(restored.error, 'boom');
      expect(restored.host, 'h');
      expect(restored.port, 22);
      expect(restored.username, 'u');
    });

    test('SshOutputEvent preserves binary bytes', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 250, 200]);
      final ev = SshOutputEvent(sessionId: 'sid', bytes: bytes);
      final restored = SshTaskEvent.fromJson(ev.toJson()) as SshOutputEvent;
      expect(restored.bytes, bytes);
    });

    test('SshLifecycleEvent preserves the formatted line verbatim (#766)', () {
      const line = '12:34:56.789 [task.host] resume-liveness: STALE → reconnect';
      const ev = SshLifecycleEvent(line: line);
      final restored = SshTaskEvent.fromJson(ev.toJson()) as SshLifecycleEvent;
      expect(restored.line, line);
      // Task-global: empty sentinel sessionId (mirrors SshTaskReadyEvent).
      expect(restored.sessionId, '');
      expect(restored.kind, SshTaskEventKind.lifecycle);
    });
  });

  group('SessionHost.encodeAuth', () {
    test('password auth encodes as type:password', () {
      final json = SessionHost.encodeAuth(const SshAuth.password('p'));
      expect(json['type'], 'password');
      expect(json['password'], 'p');
    });

    test('key auth encodes pem as base64', () {
      final pem = Uint8List.fromList([0x2D, 0x2D, 0x42, 0x45, 0x47]); // "--BEG"
      final json = SessionHost.encodeAuth(SshAuth.key(pem, passphrase: 'pp'));
      expect(json['type'], 'key');
      expect(json['pem'], isA<String>());
      expect(json['passphrase'], 'pp');
    });
  });

  group('Gateway end-to-end', () {
    /// Build a controller factory that produces controllers whose connect()
    /// is a no-op (we drive state transitions via debugSetConnectedForTest).
    SshSessionController stubControllerFactory() {
      return SshSessionController(
        socketOpener: (host, port, {timeout}) {
          // Never resolves — tests that need a connect-flow drive the
          // controller directly through debugSetConnectedForTest.
          return Future.delayed(const Duration(days: 1), () {
            throw Exception('socketOpener not used in IPC tests');
          });
        },
      );
    }

    test('UI proxy receives state events emitted by the host', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: stubControllerFactory,
        snapshotInterval: const Duration(hours: 1), // disabled in this test
      );
      addTearDown(host.dispose);
      final proxy = SshSessionProxy(sessionId: 'sid-a', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      final states = <SshSessionState>[];
      final sub = proxy.stream.listen((d) => states.add(d.state));

      proxy.connect(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // First state event the host emits is `connecting` from
      // SshSessionController.connect — capture at least one transition.
      expect(states, isNotEmpty);
      expect(states.first, SshSessionState.connecting);

      await sub.cancel();
    });

    test('host emits snapshots on demand', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: stubControllerFactory,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.dispose);
      final proxy = SshSessionProxy(sessionId: 'sid-x', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      proxy.connect(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Feed some output through the host so metrics tick.
      host.ingestOutputForTest(
        'sid-x',
        Uint8List.fromList([0x48, 0x69, 0x0A]), // "Hi\n"
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Request a snapshot.
      proxy.rebind();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(proxy.snapshot.bytesIn, greaterThanOrEqualTo(3));
      expect(proxy.snapshot.scrollbackTail, contains('Hi'));
    });

    test('disconnect command tears down the hosted session', () async {
      final pair = InMemoryGatewayPair();
      addTearDown(pair.dispose);
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: stubControllerFactory,
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(host.dispose);
      final proxy = SshSessionProxy(sessionId: 'sid-d', gateway: pair.uiSide);
      addTearDown(proxy.dispose);

      proxy.connect(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.sessionIds, contains('sid-d'));

      proxy.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.sessionIds, isNot(contains('sid-d')));
    });
  });
}
