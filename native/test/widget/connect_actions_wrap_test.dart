// Connect chooser action row (#1124): the two-button Row became a three-action
// Wrap (New connection / Import / Export). Locks that all three actions render
// and are tappable on a NARROW phone surface (320x640 logical) — the Wrap must
// flow to a second run instead of overflowing — and that the Export action
// opens the export-backup dialog.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/connect_form.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('three-action Wrap renders and is tappable at 320x640',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pair = InMemoryGatewayPair();
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        profilesStoreProvider.overrideWithValue(ProfilesStore()),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(backend: InMemorySecretsBackend()),
        ),
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

    // The action row is a Wrap now (three buttons can't share one 320dp row).
    expect(
      find.descendant(
        of: find.byType(ConnectForm),
        matching: find.byType(Wrap),
      ),
      findsWidgets,
    );

    final newKey = find.byKey(const Key('new-connection'));
    final importKey = find.byKey(const Key('open-import-profiles-dialog'));
    final exportKey = find.byKey(const Key('open-export-backup-dialog'));
    expect(newKey, findsOneWidget);
    expect(importKey, findsOneWidget);
    expect(exportKey, findsOneWidget);
    expect(newKey.hitTestable(), findsOneWidget);
    expect(importKey.hitTestable(), findsOneWidget);
    expect(exportKey.hitTestable(), findsOneWidget);

    // Export opens the export-backup dialog.
    await tester.tap(exportKey);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('export-backup-dialog')), findsOneWidget);
  });
}
