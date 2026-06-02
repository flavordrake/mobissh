// Widget tests for the decluttered profile CHOOSER home view (#583).
//
// Locks the #583 contract:
//   1. The home view (ConnectForm chooser) renders the profile list + a "New"
//      affordance + Import, and does NOT contain the removed inline form
//      (no connect-submit, no host/port TextFields, no status panel).
//   2. The host-key prompt listener is STILL present off the formless chooser:
//      when sshSessionDataProvider emits a pendingHostKey, the Trust dialog is
//      shown. THIS is the regression guard for the relocation trap.
//   3. Tapping "New connection" opens the editor in create mode (blank fields);
//      Save upserts a profile.
//
// Sessions are proxy-backed; taskSshGatewayProvider is overridden with an
// in-memory gateway pair so the connect path runs without binding to platform
// statics.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
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

ProviderContainer _container({
  required ProfilesStore store,
  required SecretsStore secrets,
  required InMemoryGatewayPair pair,
}) {
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store),
      secretsStoreProvider.overrideWithValue(secrets),
    ],
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('chooser renders profile list + New + Import; no inline form', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ConnectForm()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Present: the New affordance + the Import action.
    expect(find.byKey(const Key('new-connection')), findsOneWidget);
    expect(
      find.byKey(const Key('open-import-profiles-dialog')),
      findsOneWidget,
    );
    // Empty profile list hint is present (no profiles seeded).
    expect(find.byKey(const Key('profile-list-empty')), findsOneWidget);

    // ABSENT: the removed inline form — no Connect button, no host/port/
    // username/password fields on the home view.
    expect(find.byKey(const Key('connect-submit')), findsNothing);
    expect(find.byKey(const Key('connect-host')), findsNothing);
    expect(find.byKey(const Key('connect-port')), findsNothing);
    expect(find.byKey(const Key('connect-username')), findsNothing);
    expect(find.byKey(const Key('connect-password')), findsNothing);
    expect(find.byKey(const Key('connect-initial-command')), findsNothing);
    // ABSENT: the status panel text.
    expect(find.textContaining('State:'), findsNothing);
  });

  testWidgets('host-key prompt listener is present off the formless chooser '
      '(relocation regression guard)', (tester) async {
    // Seed a password profile + its vault secret so a tap connects.
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await secrets.write('vault-1', <String, Object?>{'password': 'pw'});
    await store.save(<SavedProfile>[
      SavedProfile(
        title: 'Box',
        host: 'box.example',
        port: 22,
        username: 'alice',
        authType: 'password',
        vaultId: 'vault-1',
      ),
    ]);

    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ConnectForm()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap the profile to connect — this creates the session entry whose proxy
    // the host-key listener watches via sshSessionDataProvider.
    await tester.tap(
      find.byKey(const Key('profile-tile-box.example:22:alice')),
    );
    await _pumpFrames(tester, count: 30);

    // Drive a host-key challenge from the task side through the gateway. The
    // proxy turns it into a pendingHostKey; the chooser's
    // ref.listen(sshSessionDataProvider) must then fire showHostKeyDialog.
    final entry = container.read(sessionsProvider).entries.first;
    pair.taskSide.send(
      SshHostKeyChallengeEvent(
        sessionId: entry.id,
        host: 'box.example',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc123',
      ).toJson(),
    );
    await _pumpFrames(tester, count: 20);

    // The Trust + connect dialog appeared — the listener survived the form
    // removal. Without the relocated listener, no dialog renders.
    expect(find.text('Trust + connect'), findsOneWidget);
  });

  testWidgets('New connection opens the editor in create mode; Save upserts', (
    tester,
  ) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(store: store, secrets: secrets, pair: pair);
    addTearDown(container.dispose);

    // Tall surface so the editor's Save button is on-screen and hit-testable.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ConnectForm()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-connection')));
    await tester.pumpAndSettle();

    // Editor opened in create mode: title says "New connection", fields blank.
    expect(find.byKey(const Key('profile-editor')), findsOneWidget);
    expect(find.text('New connection'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('profile-editor-host')))
          .controller
          ?.text,
      isEmpty,
    );

    // Fill in a new connection + Save (plain save, not connect).
    await tester.enterText(
      find.byKey(const Key('profile-editor-host')),
      'new.example',
    );
    await tester.enterText(
      find.byKey(const Key('profile-editor-username')),
      'carol',
    );
    final save = find.byKey(const Key('profile-editor-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final list = await store.load();
    expect(list.length, 1);
    expect(list.first.host, 'new.example');
    expect(list.first.username, 'carol');
    // No session created on a plain Save.
    expect(container.read(sessionsProvider).entries, isEmpty);
  });
}
