// Desktop gateway wiring (#577).
//
// On a desktop platform the app hosts the `SessionHost` IN-PROCESS (no
// foreground service, no task isolate) and connects SSH directly over
// dart:io. The selection is driven by [isDesktopProvider], which is injected
// so these tests never read the real `Platform`.
//
// Two facts are asserted:
//   1. With the desktop flag forced TRUE, `taskSshGatewayProvider` resolves to
//      an in-process gateway backed by a LIVE `SessionHost` — proven by driving
//      a `connect` through a proxy on the gateway's UI side and observing the
//      host emit state events back (the host's `SshSessionController` reacts).
//      It is NOT a `FlutterForegroundSshGateway`.
//   2. With the desktop flag forced FALSE (android), it resolves to the
//      `FlutterForegroundSshGateway` (FFT-backed) — no in-process host exists.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/platform/desktop.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';

void main() {
  group('taskSshGatewayProvider platform selection (#577)', () {
    test(
      'desktop flag → in-process gateway backed by a live SessionHost',
      () async {
        final container = ProviderContainer(
          overrides: [isDesktopProvider.overrideWithValue(true)],
        );
        addTearDown(container.dispose);

        final gateway = container.read(taskSshGatewayProvider);

        // Desktop path must NOT use the foreground-task gateway.
        expect(gateway, isNot(isA<FlutterForegroundSshGateway>()));

        // Prove a live SessionHost is wired to the task side: drive a connect
        // through a proxy on the UI side and observe state events flow back.
        // (Connect to an unreachable host — it never completes, but the host's
        // controller emits `connecting` immediately, proving it processed the
        // command. A dead/unwired gateway would emit nothing.)
        final proxy = SshSessionProxy(
          sessionId: 'desktop-sid',
          gateway: gateway,
        );
        addTearDown(proxy.dispose);

        final states = <SshSessionState>[];
        final sub = proxy.stream.listen((d) => states.add(d.state));

        proxy.connect(
          const SshConnectParams(
            host: 'unreachable.invalid',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          states,
          contains(SshSessionState.connecting),
          reason: 'in-process SessionHost should process the connect command',
        );

        await sub.cancel();
      },
    );

    test('android flag → FlutterForegroundSshGateway (FFT-backed)', () {
      final container = ProviderContainer(
        overrides: [isDesktopProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      final gateway = container.read(taskSshGatewayProvider);

      expect(gateway, isA<FlutterForegroundSshGateway>());
    });
  });

  group('keepalive gateway platform selection (#577)', () {
    test(
      'desktop flag → NoopKeepaliveGateway, never touches FFT statics',
      () async {
        final container = ProviderContainer(
          overrides: [isDesktopProvider.overrideWithValue(true)],
        );
        addTearDown(container.dispose);

        // The starter must resolve without throwing a MissingPluginException —
        // the desktop NoopKeepaliveGateway short-circuits start/stop. If the
        // FFT gateway leaked in, ensureStarted() would hit platform channels.
        final starter = container.read(keepaliveServiceStarterProvider);
        await starter();
      },
    );
  });
}
