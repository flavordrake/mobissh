// #1141 (PR C of #1117) — R15 trap: a warm link that arrives while NO chooser
// is mounted (a terminal is showing) must still reach the host-key prompt.
//
// The router hands the authorised profile off, finds nothing consumed it, and
// pushes ConnectHomePage over the current route; the ConnectForm that mounts
// consumes the hand-off through its own `_connectFromProfile`, whose TOFU
// listener then surfaces `Trust + connect` for the new session. A same-host
// profile with a different user is never touched.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/link_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
      'warm link with no chooser mounted pushes home, connects, reaches TOFU',
      (tester) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await secrets.write('vault-a', <String, Object?>{'password': 'pw'});
    await secrets.write('vault-b', <String, Object?>{'password': 'pw'});
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Alice',
        host: 'box.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-a',
        linkAutoConnect: true,
      ),
      SavedProfile(
        title: 'Bob',
        host: 'box.example',
        port: 22,
        username: 'bob',
        authType: 'password',
        vaultId: 'vault-b',
      ),
    ]);
    final pair = InMemoryGatewayPair();
    addTearDown(() async {
      await pair.dispose();
    });
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
        linkPendingStoreProvider.overrideWithValue(MapKeyValueStore()),
      ],
    );
    addTearDown(container.dispose);

    // A "terminal is showing": the root Navigator has no ConnectForm mounted.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const Scaffold(body: Text('terminal-placeholder')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ConnectHomePage), findsNothing);

    // deliver() awaits the pushed route, so it only completes on pop.
    // ignore: unawaited_futures
    container
        .read(connectLinkRouterProvider)
        .deliver('mobissh://connect?host=box.example&user=alice');
    await _pumpFrames(tester, count: 30);

    expect(find.byType(ConnectHomePage), findsOneWidget,
        reason: 'nothing consumed the hand-off → home pushed over the terminal');
    expect(container.read(pendingLinkConnectProvider), isNull,
        reason: 'one-shot: consumed by the mounted chooser');
    final entries = container.read(sessionsProvider).entries;
    expect(entries.length, 1);
    expect(entries.single.username, 'alice');
    expect(entries.single.profileKey, 'box.example:22:alice');

    // The pushed chooser owns the TOFU listener for the link-started session.
    pair.taskSide.send(
      SshHostKeyChallengeEvent(
        sessionId: entries.single.id,
        host: 'box.example',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc123',
      ).toJson(),
    );
    await _pumpFrames(tester, count: 20);
    expect(find.text('Trust + connect'), findsOneWidget);
  });
}
