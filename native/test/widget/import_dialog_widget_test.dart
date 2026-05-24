// Widget tests for [ImportProfilesDialog] (#501).
//
// Asserts:
//   - valid pasted JSON triggers import (store state changes, dialog closes
//     with non-null ImportResult)
//   - invalid JSON keeps the dialog open and shows an inline error;
//     store state is unchanged

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/import_profiles_dialog.dart';

/// Pump a launcher that exposes a button which opens the dialog. Avoids the
/// "guarded function conflict" trap of launching the dialog from a
/// postFrameCallback inside the first pumpWidget call.
Future<ImportResult?> _openDialog(
  WidgetTester tester, {
  required ProfilesStore store,
  required Future<void> Function(WidgetTester) interact,
}) async {
  ImportResult? captured;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open-button'),
                onPressed: () async {
                  captured = await showImportProfilesDialog(context);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('valid PWA-envelope JSON imports and closes the dialog',
      (tester) async {
    final store = ProfilesStore();

    final result = await _openDialog(
      tester,
      store: store,
      interact: (t) async {
        expect(find.byKey(const Key('import-profiles-dialog')), findsOneWidget);

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
}
