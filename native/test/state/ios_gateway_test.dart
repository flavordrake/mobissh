// iOS gateway routing (#1026 gating slice).
//
// iOS has NO foreground-service equivalent, so it must take the desktop-style
// IN-PROCESS SessionHost path — never the Android flutter_foreground_task
// path. These tests force the OS to 'ios' through the
// `debugOperatingSystemOverride` seam (no provider overrides), so the FULL
// production resolution chain is exercised: kIsDesktop stays false (iOS is not
// desktop UX) while `usesInProcessHostProvider` routes hosting in-process.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/platform/desktop.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';

void main() {
  tearDown(() {
    debugOperatingSystemOverride = null;
  });

  group('iOS platform routing (#1026)', () {
    test('ios → in-process gateway backed by a live SessionHost', () async {
      debugOperatingSystemOverride = 'ios';
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // iOS is NOT desktop (UX predicate stays false)…
      expect(container.read(isDesktopProvider), isFalse);
      // …but it DOES use the in-process host (no FGS on iOS).
      expect(container.read(usesInProcessHostProvider), isTrue);

      final gateway = container.read(taskSshGatewayProvider);
      expect(gateway, isNot(isA<FlutterForegroundSshGateway>()));

      // Prove a live SessionHost is wired: drive a connect through a proxy on
      // the UI side and observe the host emit `connecting` back (same probe as
      // desktop_gateway_test.dart).
      final proxy = SshSessionProxy(sessionId: 'ios-sid', gateway: gateway);
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
        reason: 'iOS must host the SessionHost in-process',
      );

      await sub.cancel();
    });

    test('ios → NoopKeepaliveGateway, never touches FFT statics', () async {
      debugOperatingSystemOverride = 'ios';
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Must resolve + run without a MissingPluginException: the FFT-backed
      // keepalive gateway would hit platform channels on ensureStarted().
      final starter = container.read(keepaliveServiceStarterProvider);
      await starter();
    });

    test('android still → FlutterForegroundSshGateway (FFT-backed)', () {
      debugOperatingSystemOverride = 'android';
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(usesInProcessHostProvider), isFalse);
      final gateway = container.read(taskSshGatewayProvider);
      expect(gateway, isA<FlutterForegroundSshGateway>());
    });

    test(
      'usesInProcessHostProvider follows an isDesktopProvider override '
      '(existing desktop test seam keeps working)',
      () {
        final container = ProviderContainer(
          overrides: [isDesktopProvider.overrideWithValue(true)],
        );
        addTearDown(container.dispose);

        expect(container.read(usesInProcessHostProvider), isTrue);
      },
    );
  });
}
