// #1141 (PR C of #1117) — the link → ConnectForm hand-off.
//
// A matched + authorised link profile is placed in
// `pendingLinkConnectProvider`; the mounted chooser must consume it ONCE and
// route it through its own `_connectFromProfile` (the path that owns the TOFU
// listener, R15, and the missing-creds → editor fallback, R13a). Asserts the
// session created carries EXACTLY the handed-off identity — a second saved
// profile on the same host with a different user is never touched — and that
// the R26 banner renders while `linkRejectedProvider` is set.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/link_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/connect_form.dart';

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

  Future<ProviderContainer> pumpChooser(WidgetTester tester) async {
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
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ConnectForm())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('a handed-off link profile connects exactly that identity once',
      (tester) async {
    final container = await pumpChooser(tester);
    final profiles = await container.read(profilesStoreProvider).load();
    final alice = profiles.firstWhere((p) => p.username == 'alice');

    container.read(pendingLinkConnectProvider.notifier).state = alice;
    await _pumpFrames(tester, count: 30);

    expect(container.read(pendingLinkConnectProvider), isNull,
        reason: 'one-shot: cleared on consume');
    final entries = container.read(sessionsProvider).entries;
    expect(entries.length, 1);
    expect(entries.single.profileKey, alice.identityKey);
    expect(entries.single.username, 'alice');
  });

  testWidgets('a hand-off with no stored creds opens the editor, no session',
      (tester) async {
    final container = await pumpChooser(tester);
    container.read(pendingLinkConnectProvider.notifier).state = SavedProfile(
      title: 'Bare',
      host: 'bare.example',
      port: 22,
      username: 'nobody',
      authType: 'password',
    );
    await _pumpFrames(tester, count: 30);
    expect(container.read(sessionsProvider).entries, isEmpty);
    expect(find.text('Bare'), findsWidgets);
  });

  testWidgets('rejected-link banner is persistent and dismissable',
      (tester) async {
    final container = await pumpChooser(tester);
    expect(find.byKey(const Key('link-rejected-banner')), findsNothing);
    container.read(linkRejectedProvider.notifier).state = true;
    await _pumpFrames(tester, count: 4);
    expect(find.text('Link not recognized'), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-rejected-dismiss')));
    await _pumpFrames(tester, count: 4);
    expect(find.byKey(const Key('link-rejected-banner')), findsNothing);
    expect(container.read(sessionsProvider).entries, isEmpty);
  });
}
