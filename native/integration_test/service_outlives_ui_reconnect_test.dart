// On-emulator: foreground service OUTLIVES the UI process (#731).
//
// Device bug (daily driver): Android kills the app but keeps / sticky-restarts
// the keepalive foreground service. A fresh app launch builds a NEW, not-ready
// `FlutterForegroundSshGateway`; `KeepaliveController._startIfStopped` sees the
// service "already running" and SKIPS (re)start, so the task never re-runs
// `onStart` and never re-emits `SshTaskReadyEvent`. The new gateway stays
// not-ready forever → every `connect` is buffered and never flushed → tapping
// any profile does NOTHING (no spinner, no error, no terminal).
//
// Why an integration test (#589): the buffering / readiness handshake crosses
// the REAL FFT task-isolate boundary and a REAL foreground service. Headless
// widget tests use `InMemoryGatewayPair`, which is always ready and never
// involves a separate service isolate — so they cannot reproduce "service alive,
// UI gateway fresh and not-ready." This class of bug shipped green before.
//
// THE SEAM (documented per the develop-agent brief):
//   1. Connect session A through the UI normally. This starts the REAL
//      foreground service + task isolate (the live, already-running service).
//   2. Simulate the UI process being replaced WITHOUT killing the service:
//      construct a BRAND-NEW `FlutterForegroundSshGateway()` bound to the same
//      FFT statics (`UiSideFftTransport`). This is exactly what a fresh cold
//      launch builds — a not-ready gateway re-binding to the live service. The
//      original gateway is left in place (the service does not care which UI
//      isolate is bound); the new one starts `_ready = false`.
//   3. Drive a `connect` through a fresh `SshSessionProxy` on the NEW gateway.
//      Pre-fix: it buffers forever. Post-fix: the re-handshake (`uiHello` via
//      `sendControl` → task re-emits ready) flips the new gateway to ready and
//      the buffered `connect` flushes.
//   4. Assert the session reaches a LIVE shell (bytes flow), not just a widget
//      mount.
//
// We can't literally kill+respawn the Dart UI isolate from inside a single
// integration_test run, so step 2 reproduces the OBSERVABLE state a fresh
// process lands in (a not-ready gateway on a live service) at the gateway seam
// — the exact layer the bug lives in. The keepalive controller's
// already-running branch is exercised through `KeepaliveController.ensureStarted`
// against the live service.
//
// Network bridge: scripts/native-connect-test.sh sets up 127.0.0.1:2222 → socat
// → test-sshd:22, same as the other connect smokes.
//
// The key below is the throwaway test fixture committed at
// docker/test-sshd/testuser_id_ed25519 — NOT a real secret.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/keepalive_task.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

Future<bool> _waitConnectedShell(
  WidgetTester tester,
  SshSessionProxy proxy, {
  int maxSlices = 80,
}) async {
  final out = <int>[];
  final sub = proxy.output.listen(out.addAll);
  var ok = false;
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (proxy.data.state == SshSessionState.connected && out.isNotEmpty) {
      ok = true;
      break;
    }
  }
  await sub.cancel();
  return ok;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fresh not-ready gateway on a live (already-running) service flushes a '
    'buffered connect via re-handshake and reaches a live shell',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      // 1. Connect session A through the UI — starts the REAL foreground service.
      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      var reachedA = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final accept = find.text('Trust + connect');
        if (accept.evaluate().isNotEmpty) {
          await tester.tap(accept.first);
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (find
            .byKey(const Key('session-menu-button'))
            .evaluate()
            .isNotEmpty) {
          reachedA = true;
          break;
        }
      }
      expect(
        reachedA,
        isTrue,
        reason: 'session A never reached the terminal — service never started',
      );

      // 2. Simulate the UI process being replaced while the service stays alive:
      //    a BRAND-NEW gateway bound to the same FFT statics — the not-ready state
      //    a fresh cold launch lands in.
      final freshGateway = FlutterForegroundSshGateway();
      addTearDown(freshGateway.dispose);
      expect(
        freshGateway.isReady,
        isFalse,
        reason: 'a fresh gateway must start not-ready (pre-handshake)',
      );

      // 3a. A fresh proxy on the new gateway, then issue a connect. While the
      //     gateway is not-ready this connect is BUFFERED (the bug: forever).
      const sidB = '127.0.0.1:2223:testuser:731';
      final proxyB = SshSessionProxy(sessionId: sidB, gateway: freshGateway);
      addTearDown(proxyB.dispose);
      proxyB.connect(
        const SshConnectParams(
          host: '127.0.0.1',
          port: 2223,
          username: 'testuser',
          auth: SshAuth.password('testpass'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        freshGateway.isReady,
        isFalse,
        reason: 'connect must be buffered: no handshake has happened yet',
      );

      // 3b. Re-handshake: a fresh UI process asks the already-running task to
      //     re-announce readiness. This is what `KeepaliveController`'s
      //     already-running branch now does. Drive it directly against the live
      //     service so the test does not depend on the chooser flow re-running.
      freshGateway.sendControl(const SshUiHelloCommand().toJson());
      freshGateway.markServiceAlreadyRunning();

      // Also exercise the controller seam: ensureStarted against a live service
      // hits the "already running" branch (idempotent, must not double-start).
      final controller = KeepaliveController(
        onServiceAlreadyRunning: () {
          freshGateway.sendControl(const SshUiHelloCommand().toJson());
        },
      );
      addTearDown(controller.dispose);
      await controller.ensureStarted();

      // 4. The re-handshake must flip the fresh gateway ready and flush the
      //    buffered connect → session B reaches a LIVE shell (bytes flow).
      final reachedB = await _waitConnectedShell(tester, proxyB);
      expect(
        freshGateway.isReady,
        isTrue,
        reason:
            'the re-handshake never flipped the fresh gateway to ready — the '
            '#731 silent-buffer deadlock',
      );
      expect(
        reachedB,
        isTrue,
        reason:
            'buffered connect on the fresh gateway did not flush to a live '
            'shell after re-handshake — #731',
      );

      // Sanity: session A is still alive (the new gateway binding did not tear it
      // down).
      final entries = container.read(sessionsProvider).entries;
      expect(
        entries.any((e) => e.proxy.data.state == SshSessionState.connected),
        isTrue,
        reason: 'session A must survive a fresh gateway binding to the service',
      );
    },
  );
}
