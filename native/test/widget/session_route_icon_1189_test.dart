// Route icon + routing details on a jumped session's title (#1189, R16 of
// docs/jump-host.md).
//
// A session whose transport was built through jump hops carries a small
// monochrome route glyph on its TITLE — on the terminal session bar and on its
// session-menu row. Tapping it opens the full routing details: every hop in
// DIAL ORDER (outermost first) as `user@host:port`, then the target, each with
// its role (hop N of M / target).
//
// The icon reads the LIVE session's hops (`SessionEntry.jumpHops`, copied from
// the `SshConnectParams` the transport was built from) — NOT the profile's
// current `jumpIdentityKey`. A session opened before the profile was edited is
// still routed the old way, so showing the profile's current value would be a
// lie about a live connection; the last test pins exactly that.
//
// A session with NO hops gains zero chrome: no icon anywhere.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

SshConnectParams _hop(String host, {String user = 'jump', int port = 22}) =>
    SshConnectParams(
      host: host,
      port: port,
      username: user,
      auth: const SshAuth.password('p'),
    );

/// Terminal-screen harness (mirrors large_landscape_layout_test.dart): a real
/// `SshShell` over a fake transport per session so TerminalScreen mounts its
/// chrome (session bar included).
Future<({SessionEntry entry, ProviderContainer container})> _mountTerminal(
  WidgetTester tester, {
  required List<SshConnectParams> jumpHops,
  List<Override> extraOverrides = const [],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(400, 820);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

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
      ...extraOverrides,
    ],
  );
  addTearDown(() {
    for (final t in transports.values) {
      t.close();
    }
    container.dispose();
  });

  final entry = container
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: 'target.example.com',
          port: 22,
          username: 'deploy',
          auth: const SshAuth.password('p'),
          jumpHops: jumpHops,
        ),
        // Deliberately NOT "Target": the session-bar label must not collide
        // with the details sheet's "Target" role label.
        title: 'Prod box',
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
  return (entry: entry, container: container);
}

/// Session-menu harness (mirrors session_menu_swatch_test.dart).
Widget _menuHost(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              key: const Key('open-menu'),
              onPressed: () => showSessionMenu(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('session bar route icon (#1189)', () {
    testWidgets('a session with NO hops shows no route icon at all', (
      tester,
    ) async {
      await _mountTerminal(tester, jumpHops: const []);

      expect(find.byKey(const Key('session-route-icon')), findsNothing);
      expect(find.byKey(const Key('session-route-details')), findsNothing);
    });

    testWidgets('one hop: icon on the title, tap lists the hop + the target', (
      tester,
    ) async {
      await _mountTerminal(
        tester,
        jumpHops: [_hop('bastion.example.com', user: 'jumpuser', port: 2222)],
      );

      final icon = find.byKey(const Key('session-route-icon'));
      expect(icon, findsOneWidget);

      await tester.tap(icon);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('session-route-details')), findsOneWidget);
      expect(find.text('jumpuser@bastion.example.com:2222'), findsOneWidget);
      expect(find.text('deploy@target.example.com:22'), findsOneWidget);
      // Roles are spelled out so the list reads as a path, not a bag of hosts.
      expect(find.text('Hop 1 of 1'), findsOneWidget);
      expect(find.text('Target'), findsOneWidget);
    });

    testWidgets('three hops are listed in DIAL ORDER, target last', (
      tester,
    ) async {
      await _mountTerminal(
        tester,
        jumpHops: [_hop('edge'), _hop('middle'), _hop('inner')],
      );

      await tester.tap(find.byKey(const Key('session-route-icon')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('session-route-details')), findsOneWidget);
      expect(find.text('Hop 1 of 3'), findsOneWidget);
      expect(find.text('Hop 2 of 3'), findsOneWidget);
      expect(find.text('Hop 3 of 3'), findsOneWidget);

      // Dial order: outermost first, then the target below every hop.
      double dy(String label) => tester.getTopLeft(find.text(label)).dy;
      expect(dy('jump@edge:22'), lessThan(dy('jump@middle:22')));
      expect(dy('jump@middle:22'), lessThan(dy('jump@inner:22')));
      expect(
        dy('jump@inner:22'),
        lessThan(dy('deploy@target.example.com:22')),
      );
    });

    testWidgets(
      'details show the SESSION route even after the profile is re-pointed',
      (tester) async {
        final store = ProfilesStore();
        final m = await _mountTerminal(
          tester,
          jumpHops: [_hop('bastion.example.com', user: 'jumpuser')],
          extraOverrides: [profilesStoreProvider.overrideWithValue(store)],
        );

        // The profile is edited AFTER the session connected: its jump host now
        // points somewhere else entirely. The live session is still routed
        // through the bastion it was dialled through.
        await store.upsert(
          SavedProfile(
            title: 'Prod box',
            host: 'target.example.com',
            port: 22,
            username: 'deploy',
            jumpIdentityKey: 'elsewhere.example.com:22:other',
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('session-route-icon')));
        await tester.pumpAndSettle();

        expect(find.text('jumpuser@bastion.example.com:22'), findsOneWidget);
        expect(find.textContaining('elsewhere.example.com'), findsNothing);
        expect(m.entry.jumpHops.single.host, 'bastion.example.com');
      },
    );
  });

  group('session menu row route icon (#1189)', () {
    testWidgets('routed row gets the icon, direct row gets none', (
      tester,
    ) async {
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(sessionsProvider.notifier);
      final direct = notifier.addOrActivate(
        const SshConnectParams(
          host: 'direct-host',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      final routed = notifier.addOrActivate(
        SshConnectParams(
          host: 'routed-host',
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
          jumpHops: [_hop('bastion.example.com', user: 'jumpuser')],
        ),
      );

      await tester.pumpWidget(_menuHost(container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(
        find.byKey(Key('session-route-icon-${routed.id}')),
        findsOneWidget,
      );
      expect(find.byKey(Key('session-route-icon-${direct.id}')), findsNothing);

      // #1155's slimming stands: the routed row gains an icon, not a text line.
      expect(find.textContaining('via '), findsNothing);
      expect(find.text('jumpuser@bastion.example.com:22'), findsNothing);

      // Tapping the row icon opens the same routing details.
      await tester.tap(find.byKey(Key('session-route-icon-${routed.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-route-details')), findsOneWidget);
      expect(find.text('jumpuser@bastion.example.com:22'), findsOneWidget);
      expect(find.text('u@routed-host:22'), findsOneWidget);
    });
  });
}
