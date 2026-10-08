// #1279 G2 + G4 — guidance a link leaves the user to act on is a PERSISTENT
// banner, never a toast (feedback_actionable_guidance_not_toast).
//
// G2 / F4: a link to a host with no saved profile opens the create editor.
//   The editor shows a non-dismissible "this host came from a link" banner
//   from the first frame, so it is on screen before the key-library picker
//   can hand a stored key's signature to a host the link chose. No session.
// G4: a link connect whose jump chain cannot be resolved (here: the hop has
//   no stored credential) shows a persistent banner on the chooser naming the
//   hop. It is still there long after a toast would have gone. No session.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/link_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ProviderContainer> _app(
  WidgetTester tester,
  List<SavedProfile> profiles,
) async {
  final store = ProfilesStore();
  final secrets = SecretsStore(backend: InMemorySecretsBackend());
  await secrets.write('vault-a', <String, Object?>{'password': 'pw'});
  await store.save(profiles);
  final pair = InMemoryGatewayPair();
  addTearDown(pair.dispose);
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
      secretsStoreProvider.overrideWithValue(secrets),
      linkPendingStoreProvider.overrideWithValue(MapKeyValueStore()),
    ],
  );
  addTearDown(container.dispose);
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
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('G2: unmatched connect link → editor with a persistent '
      'provenance banner, no session', (tester) async {
    final container = await _app(tester, [
      SavedProfile(
        title: 'Alice',
        host: 'box.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-a',
      ),
    ]);

    // deliver() awaits the editor, which stays open for the whole test.
    // ignore: unawaited_futures
    container
        .read(connectLinkRouterProvider)
        .deliver('mobissh://connect?host=evil.example&user=eve');
    await _pumpFrames(tester, count: 20);

    final banner = find.byKey(const Key('profile-editor-link-provenance'));
    expect(banner, findsOneWidget);
    expect(
      find.descendant(of: banner, matching: find.byType(IconButton)),
      findsNothing,
      reason: 'the provenance banner cannot be dismissed',
    );
    expect(
      find.descendant(
        of: banner,
        matching: find.textContaining('came from a link'),
      ),
      findsOneWidget,
    );

    // Switching to key auth (where the key-library picker lives) keeps it.
    final keySegment = find.byIcon(Icons.vpn_key);
    await tester.ensureVisible(keySegment);
    await _pumpFrames(tester);
    await tester.tap(keySegment);
    await _pumpFrames(tester);
    expect(banner, findsOneWidget);
    await _pumpFrames(tester, count: 120); // 6 s: longer than any toast
    expect(banner, findsOneWidget);
    expect(container.read(sessionsProvider).entries, isEmpty);
  });

  testWidgets('G2: a saved-host edit (no link) shows no provenance banner',
      (tester) async {
    await _app(tester, const []);
    final ctx = appNavigatorKey.currentContext!;
    // ignore: unawaited_futures
    Navigator.of(ctx).push(MaterialPageRoute<void>(
      builder: (_) => ProfileEditor(
        profile: SavedProfile(
            title: 'x', host: 'h.example', port: 22, username: 'u'),
      ),
    ));
    await _pumpFrames(tester, count: 20);
    expect(find.byKey(const Key('profile-editor-link-provenance')),
        findsNothing);
  });

  testWidgets('G4: a jump-host failure on a link connect is a persistent '
      'banner, not a toast', (tester) async {
    final container = await _app(tester, [
      SavedProfile(
        title: 'Alice',
        host: 'box.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-a',
        linkAutoConnect: true,
        jumpIdentityKey: 'bastion.example:22:ops',
      ),
      SavedProfile(
        title: 'Bastion',
        host: 'bastion.example',
        port: 22,
        username: 'ops',
        authType: 'password',
      ),
    ]);

    // ignore: unawaited_futures
    container
        .read(connectLinkRouterProvider)
        .deliver('mobissh://connect?host=box.example&user=alice');
    await _pumpFrames(tester, count: 30);

    final banner = find.byKey(const Key('jump-host-error-banner'));
    expect(banner, findsOneWidget);
    expect(
      find.descendant(
        of: banner,
        matching: find.textContaining('bastion.example:22'),
      ),
      findsOneWidget,
    );
    await _pumpFrames(tester, count: 160); // 8 s
    expect(banner, findsOneWidget, reason: 'persistent until dismissed');
    expect(container.read(sessionsProvider).entries, isEmpty);

    await tester.tap(find.byKey(const Key('jump-host-error-dismiss')));
    await _pumpFrames(tester);
    expect(banner, findsNothing);
  });
}
