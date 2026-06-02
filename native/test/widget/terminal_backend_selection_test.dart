// Widget tests for the #684 backend-SELECTION render switch in TerminalScreen.
//
// These gate the SWITCH (which widget mounts), NOT flterm's rendering — the
// libghostty-backed flterm view can't paint headless, so the ghostty branch is
// device-validated by the owner. We assert:
//   1. Default (xterm): the xterm `TerminalView` mounts; no GhosttyTerminalView.
//   2. backend=ghostty: a GhosttyTerminalView mounts; no xterm `TerminalView`.
//
// `GhosttyTerminalView` defends against a failed libghostty load by catching
// the controller-construction error and rendering a keyed error container
// (`ghostty-terminal-error`), so the test stays green whether or not the native
// .so is present in the headless test host — it asserts the WIDGET is selected,
// which is the switch logic #684 introduces.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_backend.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

Future<ProviderContainer> _mountWithBackend(
  WidgetTester tester,
  FakeSshShellTransport transport, {
  List<Override> overrides = const [],
}) async {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => transport,
      ),
      ...overrides,
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });

  container
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('TerminalScreen backend switch (#684)', () {
    testWidgets('default backend mounts the xterm TerminalView, not ghostty', (
      tester,
    ) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final container = await _mountWithBackend(tester, transport);
      addTearDown(container.dispose);

      // Sanity: the default really is xterm.
      expect(container.read(terminalBackendProvider), TerminalBackend.xterm);
      expect(find.byType(TerminalView), findsWidgets);
      expect(find.byType(GhosttyTerminalView), findsNothing);
    });

    testWidgets('backend=ghostty mounts GhosttyTerminalView, not xterm', (
      tester,
    ) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final container = await _mountWithBackend(
        tester,
        transport,
        overrides: [
          terminalBackendProvider.overrideWith(
            (ref) => TerminalBackendNotifier()..set(TerminalBackend.ghostty),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(terminalBackendProvider), TerminalBackend.ghostty);
      // The ghostty branch is selected — its widget mounts (whether it renders
      // the flterm grid or the keyed error fallback depends on the native .so,
      // which is irrelevant to the SWITCH being correct).
      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      // The xterm TerminalView must NOT be mounted under the ghostty backend.
      expect(find.byType(TerminalView), findsNothing);
    });
  });
}
