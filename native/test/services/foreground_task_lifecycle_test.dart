// Lifecycle tests: task-side host survives a simulated UI pause/resume
// without losing session state. The UI proxy's cached snapshot is what the
// UI re-renders from on `AppLifecycleState.resumed` (#524 acceptance bullet
// "Swap to another Android app for 60s. Return → terminal shows the same
// prompt, no reconnect spinner").

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) {
      return Future.delayed(const Duration(days: 1), () {
        throw Exception('not used in lifecycle test');
      });
    },
  );
}

void main() {
  test(
      'UI proxy unbind during pause does not drop session — rebind sees '
      'snapshot from task side', () async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      snapshotInterval: const Duration(milliseconds: 50),
    );
    addTearDown(host.dispose);
    final proxy = SshSessionProxy(
      sessionId: 'sid-resume',
      gateway: pair.uiSide,
    );
    addTearDown(proxy.dispose);

    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Simulate active output.
    host.ingestOutputForTest(
      'sid-resume',
      Uint8List.fromList(
          'user@host:~\$ history\n  1  ls\n  2  cd /tmp\n'.codeUnits),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Simulate AppLifecycleState.paused → UI unbinds.
    proxy.unbind();

    // Task continues to receive output while the UI is paused.
    host.ingestOutputForTest(
      'sid-resume',
      Uint8List.fromList('  3  whoami\nuser\n'.codeUnits),
    );
    // Wait long enough for a snapshot tick (which the proxy is not
    // currently listening for — that's the point of unbind).
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // The host has the latest scrollback. The proxy's snapshot is stale
    // because it was unbound.
    expect(host.metricsOf('sid-resume')!.bytesIn, greaterThan(0));

    // Simulate AppLifecycleState.resumed → UI rebinds + requests snapshot.
    proxy.rebind();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // After rebind, the proxy's cached snapshot reflects the full
    // scrollback. "history" command lines + the post-pause output are
    // visible.
    final tail = proxy.snapshot.scrollbackTail;
    expect(tail, contains('whoami'));
  });

  test('multiple sessions remain isolated across pause/resume', () async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      snapshotInterval: const Duration(milliseconds: 50),
    );
    addTearDown(host.dispose);

    final proxies = <SshSessionProxy>[];
    for (var i = 0; i < 5; i++) {
      final p = SshSessionProxy(
        sessionId: 'sid-$i',
        gateway: pair.uiSide,
      );
      proxies.add(p);
      addTearDown(p.dispose);
      p.connect(SshConnectParams(
        host: 'h$i',
        port: 22,
        username: 'u',
        auth: const SshAuth.password('p'),
      ));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.sessionIds.length, 5);

    // Pause all proxies.
    for (final p in proxies) {
      p.unbind();
    }

    // Tick output on each session independently.
    for (var i = 0; i < 5; i++) {
      host.ingestOutputForTest(
        'sid-$i',
        Uint8List.fromList('session $i output\n'.codeUnits),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Resume.
    for (final p in proxies) {
      p.rebind();
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Each proxy's snapshot tail mentions its own session id only.
    for (var i = 0; i < 5; i++) {
      expect(proxies[i].snapshot.scrollbackTail, contains('session $i'));
      for (var j = 0; j < 5; j++) {
        if (j == i) continue;
        expect(proxies[i].snapshot.scrollbackTail, isNot(contains('session $j')));
      }
    }
  });
}
