// Widget tests for the key-row public-key dialog (#1122): tapping a library
// key row with a known publicKey shows the full OpenSSH public line with a
// Copy button (the line is NON-secret); a row without one opens nothing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/keys_screen.dart';

import '../support/test_keys.dart';

Future<void> _pump(WidgetTester tester, {required KeysStore keysStore}) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keysStoreProvider.overrideWithValue(keysStore),
        secretsStoreProvider
            .overrideWithValue(SecretsStore(backend: InMemorySecretsBackend())),
        profilesStoreProvider.overrideWithValue(ProfilesStore()),
      ],
      child: const MaterialApp(home: KeysScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mirror version_row_widget_test.dart: mock BOTH the hardened
  // `mobissh/clipboard` channel and the standard platform clipboard so the
  // copy path works regardless of which route copyToClipboard takes.
  final clipboard = <String, dynamic>{};

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clipboard.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      (call) async {
        if (call.method == 'setText') {
          clipboard['text'] = (call.arguments as Map)['text'];
          return true;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard['text'] = (call.arguments as Map)['text'];
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipboard['text']};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('tapping a row with a publicKey shows the line; Copy copies '
      'exactly the line', (tester) async {
    final keysStore = KeysStore();
    await keysStore.upsert(const SavedKey(
      id: 'k1',
      name: 'work laptop',
      algorithm: 'ed25519',
      publicKey: kTestEd25519PublicLine,
      fingerprint: kTestEd25519Fingerprint,
      createdAtMs: 1,
    ));
    await _pump(tester, keysStore: keysStore);

    await tester.tap(find.text('work laptop'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('keys-pubkey-dialog')), findsOneWidget);
    expect(find.textContaining(kTestEd25519PublicLine), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('keys-pubkey-copy')));
    await tester.pumpAndSettle();

    // Copy = the public line ONLY (it is non-secret; nothing else rides along).
    expect(clipboard['text'], kTestEd25519PublicLine);
  });

  testWidgets('tapping a row without a publicKey opens no dialog',
      (tester) async {
    final keysStore = KeysStore();
    await keysStore.upsert(const SavedKey(
      id: 'k2',
      name: 'opaque key',
      createdAtMs: 1,
    ));
    await _pump(tester, keysStore: keysStore);

    await tester.tap(find.text('opaque key'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('keys-pubkey-dialog')), findsNothing);
  });
}
