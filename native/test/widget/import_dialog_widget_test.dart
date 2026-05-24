// Widget tests for [ImportProfilesDialog] (#501, #510, #520).
//
// Asserts:
//   - file picker button exists and is the primary affordance (#520)
//   - picked file bytes drive the same parseImport/applyParsedImport path
//     as paste (smoketest, no platform channel binding)
//   - paste textarea is collapsed behind a disclosure but still works
//     end-to-end (legacy + power-user path)
//   - invalid JSON keeps the dialog open and shows an inline error;
//     store state is unchanged
//   - vault envelopes prompt for the master password

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/import_profiles_dialog.dart';

/// Test adapter that returns a pre-configured [PickedFile] (or null for
/// "user cancelled"). Avoids binding to the `file_picker` platform channel,
/// which is unavailable in `flutter_test`.
class _FakeFilePickerAdapter implements FilePickerAdapter {
  _FakeFilePickerAdapter({this.result});
  final PickedFile? result;

  @override
  Future<PickedFile?> pickJsonFile() async => result;
}

/// Pump a launcher that exposes a button which opens the dialog. Avoids the
/// "guarded function conflict" trap of launching the dialog from a
/// postFrameCallback inside the first pumpWidget call.
Future<ImportResult?> _openDialog(
  WidgetTester tester, {
  required ProfilesStore store,
  SecretsStore? secrets,
  FilePickerAdapter? pickerAdapter,
  required Future<void> Function(WidgetTester) interact,
}) async {
  ImportResult? captured;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        if (secrets != null) secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open-button'),
                onPressed: () async {
                  captured = await showImportProfilesDialog(
                    context,
                    pickerAdapter:
                        pickerAdapter ?? const DefaultFilePickerAdapter(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // Tap to open the dialog. pumpAndSettle lets the dialog finish its
  // entrance animation.
  await tester.tap(find.byKey(const Key('open-button')));
  await tester.pumpAndSettle();

  // Run the test's interaction. May tap Submit (closes dialog) or Cancel.
  await interact(tester);
  await tester.pumpAndSettle();

  return captured;
}

/// Tap the paste disclosure to reveal the textarea before driving it.
/// The two pre-#520 paste tests assume the textarea is visible; #520 moved
/// it behind an ExpansionTile.
Future<void> _expandPasteDisclosure(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('import-profiles-paste-disclosure')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('file picker button is the primary affordance (#520 smoketest)',
      (tester) async {
    final store = ProfilesStore();

    await _openDialog(
      tester,
      store: store,
      interact: (t) async {
        // The picker button is present and visible without any disclosure.
        expect(
          find.byKey(const Key('import-profiles-pick-file')),
          findsOneWidget,
        );

        // The paste field, by contrast, is hidden until the disclosure
        // is expanded — the picker is the primary path.
        expect(
          find.byKey(const Key('import-profiles-input')),
          findsNothing,
        );

        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );
  });

  testWidgets('picked file bytes drive the same import as paste (#520)',
      (tester) async {
    final store = ProfilesStore();

    const validJson = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    { "title": "Home NAS", "host": "nas.example", "port": 22,
      "username": "me", "theme": "dark" }
  ]
}
''';

    final fakePicker = _FakeFilePickerAdapter(
      result: PickedFile(
        name: 'mobissh-profiles-2026-05-22T13-00-00.json',
        bytes: Uint8List.fromList(utf8.encode(validJson)),
      ),
    );

    final result = await _openDialog(
      tester,
      store: store,
      pickerAdapter: fakePicker,
      interact: (t) async {
        await t.tap(find.byKey(const Key('import-profiles-pick-file')));
        await t.pumpAndSettle();

        // Summary surfaces the selected file's contents.
        expect(
          find.byKey(const Key('import-profiles-picked-name')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('import-profiles-picked-summary')),
          findsOneWidget,
        );
        expect(find.textContaining('1 profile'), findsOneWidget);

        await t.tap(find.byKey(const Key('import-profiles-submit')));
      },
    );

    // Dialog closed, result matches the paste-path outcome.
    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);
    expect(result, isNotNull);
    expect(result!.added, 1);

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.host, 'nas.example');
  });

  testWidgets('valid PWA-envelope JSON imports and closes the dialog',
      (tester) async {
    final store = ProfilesStore();

    final result = await _openDialog(
      tester,
      store: store,
      interact: (t) async {
        expect(find.byKey(const Key('import-profiles-dialog')), findsOneWidget);
        await _expandPasteDisclosure(t);

        const validJson = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    { "title": "Home NAS", "host": "nas.example", "port": 22,
      "username": "me", "theme": "dark" }
  ]
}
''';
        await t.enterText(
          find.byKey(const Key('import-profiles-input')),
          validJson,
        );
        await t.pump();
        await t.tap(find.byKey(const Key('import-profiles-submit')));
      },
    );

    // Dialog should be closed.
    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);

    expect(result, isNotNull);
    expect(result!.added, 1);

    // Store should reflect the import.
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.host, 'nas.example');
  });

  testWidgets('invalid JSON shows inline error and leaves store untouched',
      (tester) async {
    final store = ProfilesStore();

    final result = await _openDialog(
      tester,
      store: store,
      interact: (t) async {
        expect(find.byKey(const Key('import-profiles-dialog')), findsOneWidget);
        await _expandPasteDisclosure(t);

        await t.enterText(
          find.byKey(const Key('import-profiles-input')),
          'this is not json',
        );
        await t.pump();
        await t.tap(find.byKey(const Key('import-profiles-submit')));
        await t.pumpAndSettle();

        // Dialog should still be open with an error message visible.
        expect(find.byKey(const Key('import-profiles-dialog')), findsOneWidget);
        expect(find.byKey(const Key('import-profiles-error')), findsOneWidget);

        // Cancel to close so the future resolves.
        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );

    expect(result, isNull, reason: 'cancelled dialog returns null');

    final loaded = await store.load();
    expect(loaded, isEmpty, reason: 'invalid JSON must not corrupt storage');
  });

  testWidgets('envelope containing a vault prompts for master password',
      (tester) async {
    // Smoketest: paste an envelope with a `vault` field. The dialog must
    // switch to its stage-2 password prompt (key: import-profiles-password)
    // WITHOUT writing any profile to storage. We don't test successful
    // decryption here — that's covered by profiles_store_test.dart's
    // applyParsedImport round-trip. This proves the UI is wired up to detect
    // the envelope shape and render the prompt.
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());

    final result = await _openDialog(
      tester,
      store: store,
      secrets: secrets,
      interact: (t) async {
        await _expandPasteDisclosure(t);
        // The vault payload here is intentionally not decryptable — we only
        // care that detection works and the prompt appears, then we cancel.
        const envelopeWithVault = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    { "host": "h.example", "port": 22, "username": "u", "vaultId": "v1" }
  ],
  "vault": {
    "encrypted": "{\\"v1\\":{\\"iv\\":\\"aa\\",\\"ct\\":\\"bb\\"}}",
    "meta": "{\\"salt\\":\\"cc\\"}"
  }
}
''';
        await t.enterText(
          find.byKey(const Key('import-profiles-input')),
          envelopeWithVault,
        );
        await t.pump();
        await t.tap(find.byKey(const Key('import-profiles-submit')));
        await t.pumpAndSettle();

        // Stage 2: password input is now visible.
        expect(
          find.byKey(const Key('import-profiles-password')),
          findsOneWidget,
        );
        // The JSON paste field is gone.
        expect(
          find.byKey(const Key('import-profiles-input')),
          findsNothing,
        );

        // Cancel — we don't need a successful decrypt for this smoke.
        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );

    expect(result, isNull,
        reason: 'cancelled at password stage → no ImportResult');
    // Profile store untouched.
    expect(await store.load(), isEmpty);
  });
}
