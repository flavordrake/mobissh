// #1259 gap 3: a partial import must never be reported silently.
//
//   - describeImportResult names profiles, keys and EVERY skipped entry's reason
//   - showImportOutcome: a clean import is a top toast (informational); one with
//     skipped entries is a persistent dialog listing every reason
//   - the import dialog closes with the result when keys were written even
//     though every profile was rejected (it used to stay open showing only the
//     first error, hiding that keys had already been imported)

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/backup.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/import_profiles_dialog.dart';

const _pass = 'correct horse battery';

class _FakeFilePicker implements FilePickerAdapter {
  _FakeFilePicker(this._pick);
  final PickedFile _pick;

  @override
  Future<PickedFile?> pickJsonFile() async => _pick;
}

Future<Map<String, Object?>> _directDecrypt(String envelope, String pass) =>
    decryptBackupEnvelope(
      envelopeJson: envelope,
      passphrase: pass,
      bounds: const BackupKdfBounds(
        minMKiB: 8,
        maxMKiB: 65536,
        minT: 1,
        maxT: 6,
        maxP: 1,
      ),
    );

Widget _host(void Function(BuildContext) onOpen) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          key: const Key('open'),
          onPressed: () => onOpen(context),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('describeImportResult', () {
    test('clean import names profiles and keys', () {
      expect(
        describeImportResult(
          ImportResult(added: 2, updated: 1, keysImported: 1),
        ),
        'Imported 3 profiles (2 new, 1 updated), 1 key.',
      );
    });

    test('partial import lists every skipped reason', () {
      final text = describeImportResult(
        ImportResult(
          added: 1,
          keysImported: 2,
          errors: const [
            'profile missing required field: host',
            'SavedKey requires a non-empty string id + name',
          ],
        ),
      );
      expect(text, startsWith('Imported 1 profile (1 new), 2 keys'));
      expect(text, contains('2 entries skipped'));
      expect(text, contains('profile missing required field: host'));
      expect(text, contains('SavedKey requires a non-empty string id + name'));
    });

    test('nothing imported says so', () {
      expect(
        describeImportResult(
          ImportResult(errors: const ['profile missing required field: host']),
        ),
        'No profiles imported; 1 entry skipped: '
        'profile missing required field: host',
      );
    });
  });

  testWidgets('skipped entries show a PERSISTENT summary with every reason', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) => showImportOutcome(
          context,
          ImportResult(
            added: 1,
            errors: const ['reason one', 'reason two'],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('import-summary-dialog')), findsOneWidget);
    // Still there long after any toast would have gone.
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const Key('import-summary-dialog')), findsOneWidget);
    final text = tester
        .widget<Text>(find.byKey(const Key('import-summary-text')))
        .data!;
    expect(text, contains('reason one'));
    expect(text, contains('reason two'));

    await tester.tap(find.byKey(const Key('import-summary-ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-summary-dialog')), findsNothing);
  });

  testWidgets('a clean import is a toast, not a dialog', (tester) async {
    await tester.pumpWidget(
      _host((context) => showImportOutcome(context, ImportResult(added: 1))),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('import-summary-dialog')), findsNothing);
    expect(find.text('Imported 1 profile (1 new).'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('keys imported but every profile rejected: the dialog closes '
      'with the full result instead of hiding the write', (tester) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final envelope = await encryptBackupEnvelope(
      payload: <String, Object?>{
        'payloadVersion': 1,
        'keys': [
          {'id': 'k1', 'name': 'Laptop key'},
        ],
        'profiles': [
          {'title': 'broken', 'port': 22, 'username': 'u'},
        ],
      },
      passphrase: _pass,
      kdf: const BackupKdfParams(mKiB: 64, t: 1, p: 1),
    );
    final picker = _FakeFilePicker(
      PickedFile(
        name: 'backup.mobissh',
        bytes: Uint8List.fromList(utf8.encode(envelope)),
      ),
    );

    ImportResult? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profilesStoreProvider.overrideWithValue(store),
          secretsStoreProvider.overrideWithValue(secrets),
        ],
        child: _host((context) async {
          result = await showDialog<ImportResult>(
            context: context,
            builder: (_) => ImportProfilesDialog(
              pickerAdapter: picker,
              backupDecryptor: _directDecrypt,
            ),
          );
        }),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-profiles-pick-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-profiles-submit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('import-profiles-password')),
      _pass,
    );
    await tester.pump();
    // The tiny-KDF decrypt is real async work — run it off the fake clock.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('import-profiles-submit')));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        tester.binding.scheduleFrame();
        if (result != null) break;
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    expect(result, isNotNull, reason: 'the dialog must close with the result');
    expect(result!.keysImported, 1);
    expect(result!.errors, ['profile missing required field: host']);
    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);
    final keys = await KeysStore(prefs: await SharedPreferences.getInstance())
        .load();
    expect(keys.single.name, 'Laptop key');
  });
}
