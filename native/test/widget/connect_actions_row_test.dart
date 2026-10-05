// Connect chooser action row. #1124 made it a Wrap (New connection / Import /
// Export, later + ssh config #1185), which on a ~411dp phone wrapped onto two
// lines and ate profile-list space. Owner: "Collapse these controls by making
// new a simple + All of these buttons should fit on one line". Locks:
//   - all four actions share ONE line at 320, 360 and 411dp, with no overflow;
//   - "New connection" is an icon-only + carrying that tooltip/semantics label;
//   - every action keeps a tap target at least 40dp tall;
//   - while a connect is in flight the + is disabled and shows a spinner;
//   - Export still opens the export-backup dialog.

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

const _newKey = Key('new-connection');
const _actionKeys = <Key>[
  _newKey,
  Key('open-import-profiles-dialog'),
  Key('open-export-backup-dialog'),
  Key('open-ssh-config-export-dialog'),
];

ProviderContainer _container(
  InMemoryGatewayPair pair, {
  ProfilesStore? store,
  SecretsStore? secrets,
}) {
  return ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      profilesStoreProvider.overrideWithValue(store ?? ProfilesStore()),
      secretsStoreProvider.overrideWithValue(
        secrets ?? SecretsStore(backend: InMemorySecretsBackend()),
      ),
    ],
  );
}

void _setWidth(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final width in <double>[320, 360, 411]) {
    testWidgets('all four actions fit on one line at ${width.toInt()}dp',
        (tester) async {
      _setWidth(tester, width);
      final semantics = tester.ensureSemantics();
      final pair = InMemoryGatewayPair();
      addTearDown(() async => pair.dispose());
      final container = _container(pair);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ConnectForm())),
        ),
      );
      await tester.pumpAndSettle();

      // A RenderFlex overflow is reported as a FlutterError the binding holds.
      expect(tester.takeException(), isNull);

      final newCenter = tester.getCenter(find.byKey(_newKey));
      for (final key in _actionKeys) {
        final f = find.byKey(key);
        expect(f, findsOneWidget);
        expect(f.hitTestable(), findsOneWidget, reason: '$key tappable');
        final rect = tester.getRect(f);
        expect((rect.center.dy - newCenter.dy).abs(), lessThan(1.0),
            reason: '$key on the same line as +');
        expect(rect.height, greaterThanOrEqualTo(40), reason: '$key height');
        expect(rect.left, greaterThanOrEqualTo(0), reason: '$key on screen');
        expect(rect.right, lessThanOrEqualTo(width), reason: '$key on screen');
      }

      // The + is icon-only and still announces itself as "New connection".
      expect(tester.widget(find.byKey(_newKey)), isA<IconButton>());
      expect(
        find.descendant(of: find.byKey(_newKey), matching: find.byType(Text)),
        findsNothing,
      );
      expect(find.byTooltip('New connection'), findsOneWidget);
      // Screen readers announce the tooltip; it lands on the button's node.
      expect(
        tester.getSemantics(find.byKey(_newKey)),
        containsSemantics(tooltip: 'New connection', isButton: true),
      );
      semantics.dispose();
    });
  }

  testWidgets('Export opens the export-backup dialog at 320dp', (tester) async {
    _setWidth(tester, 320);
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final container = _container(pair);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ConnectForm())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-export-backup-dialog')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('export-backup-dialog')), findsOneWidget);
  });

  testWidgets('while connecting the + is disabled and shows a spinner',
      (tester) async {
    _setWidth(tester, 411);
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
    final container = _container(pair, store: store, secrets: secrets);
    addTearDown(container.dispose);

    // Pushed as a second route (the "New session" chooser): the connect stays
    // in flight until the session reaches `connected`, which the in-memory
    // gateway never reports, so the chooser stays busy.
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: ConnectForm()),
      ),
    );
    await tester.pumpAndSettle();

    IconButton plus() => tester.widget<IconButton>(find.byKey(_newKey));
    expect(plus().onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('profile-tile-box.example:22:alice')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(plus().onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(_newKey),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('New connection'), findsOneWidget);
  });
}
