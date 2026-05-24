// Widget tests for [ImportProfilesDialog] (#501, #510 vault, #529 file picker).
//
// Asserts:
//   - file picker is the primary affordance; tapping it drives the adapter
//     and populates the dialog state (#529 smoketest)
//   - picked file bytes flow through parseImport/applyParsedImport (#529)
//   - paste path stays usable behind the "Paste JSON instead" disclosure
//   - valid pasted JSON imports and closes
//   - invalid JSON shows inline error; store unchanged
//   - vault envelope switches to stage-2 password prompt

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

/// Fake adapter — returns a scripted PickedFile (or null) without binding to
/// MethodChannel. Tests pass a real fake via `pickerAdapter:`.
class _FakeFilePicker implements FilePickerAdapter {
  _FakeFilePicker(this._pick);
  final PickedFile? _pick;

  @override
  Future<PickedFile?> pickJsonFile() async => _pick;
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
  final adapter = pickerAdapter ?? _FakeFilePicker(null);

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
                    pickerAdapter: adapter,
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

/// Expand the "Paste JSON instead" disclosure so the legacy paste TextField
/// is visible. Most paste-based tests need this first since #529 collapsed
/// the textarea behind a disclosure.
Future<void> _expandPaste(WidgetTester t) async {
  await t.tap(find.byKey(const Key('import-profiles-paste-disclosure')));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('file picker is the primary affordance (#529 smoketest)',
      (tester) async {
    final store = ProfilesStore();

    final result = await _openDialog(
      tester,
      store: store,
      interact: (t) async {
        // File picker button visible immediately.
        expect(
          find.byKey(const Key('import-profiles-pick-file')),
          findsOneWidget,
        );
        // Paste textarea is hidden until the disclosure expands.
        expect(
          find.byKey(const Key('import-profiles-input')),
          findsNothing,
        );
        // Cancel to satisfy the future.
        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );
    expect(result, isNull);
    expect(await store.load(), isEmpty);
  });

  testWidgets('picked file bytes drive the same import as paste (#529)',
      (tester) async {
    final store = ProfilesStore();

    const validJson = '''
{
  "version": 1,
  "exportedAt": "2026-05-22T13:00:00.000Z",
  "profiles": [
    { "title": "Picked via file", "host": "f.example", "port": 22,
      "username": "me" }
  ]
}
''';
    final fake = _FakeFilePicker(PickedFile(
      name: 'mobissh-profiles-test.json',
      bytes: Uint8List.fromList(utf8.encode(validJson)),
    ));

    final result = await _openDialog(
      tester,
      store: store,
      pickerAdapter: fake,
      interact: (t) async {
        await t.tap(find.byKey(const Key('import-profiles-pick-file')));
        await t.pumpAndSettle();
        // Summary line is shown after the pick.
        expect(
          find.byKey(const Key('import-profiles-picked-name')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('import-profiles-picked-summary')),
          findsOneWidget,
        );
        // Submit drives the same parse + apply pipeline as paste.
        await t.tap(find.byKey(const Key('import-profiles-submit')));
      },
    );

    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);
    expect(result, isNotNull);
    expect(result!.added, 1);
    final loaded = await store.load();
    expect(loaded.single.host, 'f.example');
  });

  testWidgets('valid PWA-envelope JSON imports and closes the dialog',
      (tester) async {
    final store = ProfilesStore();

    final result = await _openDialog(
      tester,
      store: store,
      interact: (t) async {
        expect(find.byKey(const Key('import-profiles-dialog')), findsOneWidget);
        await _expandPaste(t);

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
        await _expandPaste(t);

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
        await _expandPaste(t);

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
