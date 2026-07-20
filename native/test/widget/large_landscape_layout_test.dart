// #1086 — large-landscape layout (Slices B/C/D).
//
// Drives the breakpoint via `tester.view.physicalSize` and asserts the three
// layout differences a wide/landscape surface adopts vs a phone:
//   B. keybar hidden by DEFAULT in large-landscape (but an explicit toggle wins).
//   C. the terminal session bar moves to the TOP (above the terminal) instead of
//      the bottom.
//   D. the home nav moves to a side NavigationRail instead of the bottom bar.
//
// Terminal harness mirrors keybar_per_session_test.dart: an InMemoryGatewayPair
// + a real SshShell per session so TerminalScreen mounts its chrome. Home
// harness mirrors home_bottom_nav_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/main.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/keybar.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

// Logical sizes at dpr 1.0.
const Size _kPhone = Size(400, 820); // portrait phone
const Size _kLargeLandscape = Size(1280, 800); // tablet / desktop-mode

void _useSize(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<({SessionEntry a, SessionEntry b, ProviderContainer container})>
_mountTerminal(WidgetTester tester, Size size) async {
  _useSize(tester, size);
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());

  final transports = <String, FakeSshShellTransport>{};
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellProvider.overrideWith((ref, sessionId) async {
        final entry = ref
            .read(sessionsProvider)
            .entries
            .firstWhere((e) => e.id == sessionId);
        final transport = transports.putIfAbsent(
          sessionId,
          FakeSshShellTransport.new,
        );
        final shell = SshShell(transport);
        shell.attach(entry.terminal);
        ref.onDispose(shell.dispose);
        return shell;
      }),
    ],
  );
  addTearDown(() {
    for (final t in transports.values) {
      t.close();
    }
    container.dispose();
  });

  final notifier = container.read(sessionsProvider.notifier);
  final a = notifier.addOrActivate(
    const SshConnectParams(
      host: 'host-a',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ),
    title: 'Session A',
  );
  final b = notifier.addOrActivate(
    const SshConnectParams(
      host: 'host-b',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ),
    title: 'Session B',
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (a: a, b: b, container: container);
}

ProviderContainer _homeContainer(InMemoryGatewayPair pair) {
  return ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(ProfilesStore()),
      secretsStoreProvider.overrideWithValue(
        SecretsStore(backend: InMemorySecretsBackend()),
      ),
    ],
  );
}

Future<void> _mountHome(
  WidgetTester tester,
  Size size,
  ProviderContainer container,
) async {
  _useSize(tester, size);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ConnectHomePage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('terminal chrome (Slices B + C)', () {
    testWidgets('phone: keybar shown, session bar at the BOTTOM', (
      tester,
    ) async {
      final m = await _mountTerminal(tester, _kPhone);

      expect(find.byType(Keybar), findsOneWidget, reason: 'phone shows keybar');

      final barTop = tester.getTopLeft(find.byKey(const Key('session-bar'))).dy;
      final bodyTop = tester
          .getTopLeft(find.byKey(ValueKey('terminal-body-${m.b.id}')))
          .dy;
      expect(
        barTop,
        greaterThan(bodyTop),
        reason: 'phone: session bar sits below the terminal body',
      );
    });

    testWidgets('large-landscape: keybar hidden, session bar at the TOP', (
      tester,
    ) async {
      final m = await _mountTerminal(tester, _kLargeLandscape);

      expect(
        find.byType(Keybar),
        findsNothing,
        reason: 'large-landscape hides the keybar by default (#1086 B)',
      );

      final barTop = tester.getTopLeft(find.byKey(const Key('session-bar'))).dy;
      final bodyTop = tester
          .getTopLeft(find.byKey(ValueKey('terminal-body-${m.b.id}')))
          .dy;
      expect(
        barTop,
        lessThan(bodyTop),
        reason: 'large-landscape: session bar sits above the terminal (#1086 C)',
      );
    });

    testWidgets(
      'large-landscape: an explicit keybar toggle SHOWS the keybar (explicit '
      'wins)',
      (tester) async {
        final m = await _mountTerminal(tester, _kLargeLandscape);
        expect(find.byType(Keybar), findsNothing);

        // The user explicitly shows the keybar for the active session (b).
        m.container
            .read(sessionAppearanceProvider.notifier)
            .setKeybarVisible(m.b.id, true);
        await tester.pump();

        expect(
          find.byType(Keybar),
          findsOneWidget,
          reason: 'explicit show beats the large-landscape hide-by-default',
        );
      },
    );
  });

  group('session menu anchor (#1086, owner 2026-07-20)', () {
    testWidgets('tablet: menu drops DOWN from the top strip, width-capped', (
      tester,
    ) async {
      await _mountTerminal(tester, _kLargeLandscape);

      await tester.tap(find.byKey(const Key('session-bar-open-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SessionMenu), findsOneWidget);
      final menuRect = tester.getRect(find.byType(SessionMenu));
      // Drops from the top strip, not the bottom: its top sits in the upper
      // quarter of the 800px-tall surface ("menu should extend from the menu
      // bar").
      expect(
        menuRect.top,
        lessThan(200),
        reason: 'tablet menu anchors just under the top bar, not the bottom',
      );
      // Left-anchored dropdown, not a full-width sheet (well under the 1280px
      // tablet width).
      expect(menuRect.left, lessThan(1));
      expect(menuRect.width, lessThanOrEqualTo(kTabletSessionMenuWidth));
    });

    testWidgets('phone: menu rises from the BOTTOM, full-width', (tester) async {
      await _mountTerminal(tester, _kPhone);

      await tester.tap(find.byKey(const Key('session-bar-open-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SessionMenu), findsOneWidget);
      final menuRect = tester.getRect(find.byType(SessionMenu));
      // Bottom-anchored: its bottom edge is at/near the screen bottom (above
      // the bar), and it spans the full 400px width.
      expect(
        menuRect.bottom,
        greaterThan(600),
        reason: 'phone menu stays bottom-anchored',
      );
      expect(menuRect.width, greaterThan(360));
    });
  });

  group('home navigation (Slice D)', () {
    testWidgets('phone: bottom NavigationBar, no side rail', (tester) async {
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = _homeContainer(pair);
      addTearDown(container.dispose);

      await _mountHome(tester, _kPhone, container);

      expect(find.byKey(const Key('home-bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('home-side-nav')), findsNothing);
    });

    testWidgets('large-landscape: side NavigationRail, no bottom bar', (
      tester,
    ) async {
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = _homeContainer(pair);
      addTearDown(container.dispose);

      await _mountHome(tester, _kLargeLandscape, container);

      expect(
        find.byKey(const Key('home-side-nav')),
        findsOneWidget,
        reason: 'large-landscape moves the nav to a side rail (#1086 D)',
      );
      expect(
        find.byKey(const Key('home-bottom-nav')),
        findsNothing,
        reason: 'the bottom nav is gone in large-landscape',
      );
    });
  });
}
