// Wire-contract round-trip tests for the port-forward IPC envelopes (#1047).
//
// Mirrors task_ipc_test.dart: every forward command and the forward-list
// status event must round-trip through toJson/fromJson without losing
// information — the task-side host and UI-side proxy both rely on it.
// [SYNC] single-codebase wire contract (both isolates are session_messages.dart);
// this round-trip suite is the sync check.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';

void main() {
  group('forward command round-trips (#1047)', () {
    test('SshForwardAddCommand preserves all fields', () {
      const cmd = SshForwardAddCommand(
        sessionId: 'h:22:u:1',
        localPort: 18088,
        remoteHost: '127.0.0.1',
        remotePort: 8088,
      );
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshForwardAddCommand>());
      restored as SshForwardAddCommand;
      expect(restored.kind, SshTaskCommandKind.forwardAdd);
      expect(restored.sessionId, 'h:22:u:1');
      expect(restored.localPort, 18088);
      expect(restored.remoteHost, '127.0.0.1');
      expect(restored.remotePort, 8088);
    });

    test('SshForwardRemoveCommand round-trips', () {
      const cmd = SshForwardRemoveCommand(
        sessionId: 'h:22:u:1',
        localPort: 18088,
      );
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshForwardRemoveCommand>());
      restored as SshForwardRemoveCommand;
      expect(restored.kind, SshTaskCommandKind.forwardRemove);
      expect(restored.localPort, 18088);
    });

    test('SshForwardListCommand round-trips', () {
      const cmd = SshForwardListCommand(sessionId: 'h:22:u:1');
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SshForwardListCommand>());
      expect(restored.kind, SshTaskCommandKind.forwardList);
      expect(restored.sessionId, 'h:22:u:1');
    });
  });

  group('forward event round-trips (#1047)', () {
    test('SshForwardListEvent preserves per-forward status + error', () {
      const event = SshForwardListEvent(
        sessionId: 'h:22:u:1',
        forwards: [
          ForwardInfo(
            localPort: 18088,
            remoteHost: '127.0.0.1',
            remotePort: 8088,
            status: ForwardStatus.active,
          ),
          ForwardInfo(
            localPort: 2000,
            remoteHost: 'db.internal',
            remotePort: 5432,
            status: ForwardStatus.error,
            error: 'Port 2000 is already in use',
          ),
        ],
      );
      final restored = SshTaskEvent.fromJson(event.toJson());
      expect(restored, isA<SshForwardListEvent>());
      restored as SshForwardListEvent;
      expect(restored.kind, SshTaskEventKind.forwardList);
      expect(restored.sessionId, 'h:22:u:1');
      expect(restored.forwards.length, 2);
      final a = restored.forwards[0];
      expect(a.localPort, 18088);
      expect(a.remoteHost, '127.0.0.1');
      expect(a.remotePort, 8088);
      expect(a.status, ForwardStatus.active);
      expect(a.error, isNull);
      final b = restored.forwards[1];
      expect(b.localPort, 2000);
      expect(b.remoteHost, 'db.internal');
      expect(b.remotePort, 5432);
      expect(b.status, ForwardStatus.error);
      expect(b.error, 'Port 2000 is already in use');
    });

    test('SshForwardListEvent round-trips empty list', () {
      const event = SshForwardListEvent(sessionId: 'sid', forwards: []);
      final restored =
          SshTaskEvent.fromJson(event.toJson()) as SshForwardListEvent;
      expect(restored.forwards, isEmpty);
    });

    test('ForwardInfo tolerates an unknown status string (forward compat)', () {
      final restored = ForwardInfo.fromJson(const {
        'localPort': 1,
        'remoteHost': 'h',
        'remotePort': 2,
        'status': 'someFutureStatus',
      });
      // Unknown status degrades to starting (never a crash).
      expect(restored.status, ForwardStatus.starting);
    });
  });
}
