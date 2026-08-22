// Widget tests for the v2 encrypted-backup import flow (#1125) through
// [ImportProfilesDialog]:
//   - dialog title is "Import backup" (still accepts v1 files, no PWA wording)
//   - a picked v2 envelope shows the pre-decrypt summary
//   - passphrase stage carries the v2 copy + the default-OFF
//     commands/forwards checkbox (key: import-restore-commands)
//   - end-to-end: pick → passphrase → applied to stores → dialog closes with
//     an ImportResult (the caller's toast reads added/updated)
//   - v1 vault envelopes get the legacy password copy, no checkbox
//
// The decrypt seam is injected (direct call with permissive KDF bounds) — the
// production path wraps decryptBackupEnvelope in Isolate.run, which cannot
// complete under the widget test's fake clock.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/backup.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/import_profiles_dialog.dart';

const _pass = 'correct horse battery';
const _tinyKdf = BackupKdfParams(mKiB: 64, t: 1, p: 1);
const _testBounds = BackupKdfBounds(
  minMKiB: 8,
  maxMKiB: 65536,
  minT: 1,
  maxT: 6,
  maxP: 1,
);

Future<Map<String, Object?>> _directDecrypt(
  String envelopeJson,
  String passphrase,
) =>
    decryptBackupEnvelope(
      envelopeJson: envelopeJson,
      passphrase: passphrase,
      bounds: _testBounds,
    );

class _FakeFilePicker implements FilePickerAdapter {
  _FakeFilePicker(this._pick);
  final PickedFile? _pick;

  @override
  Future<PickedFile?> pickJsonFile() async => _pick;
}

Future<String> _tinyEnvelope() => encryptBackupEnvelope(
      payload: <String, Object?>{
        'payloadVersion': 1,
        'profiles': [
          {
            'title': 'Box',
            'host': 'h.example',
            'port': 22,
            'username': 'me',
            'authType': 'password',
            'vaultId': 'profile-h.example:22:me',
          },
        ],
        'secrets': {
          'profile-h.example:22:me': {'password': 'hunter2hunter2'},
        },
      },
      passphrase: _pass,
      kdf: _tinyKdf,
    );

Future<ImportResult?> _openDialog(
  WidgetTester tester, {
  required ProfilesStore store,
  required SecretsStore secrets,
  FilePickerAdapter? pickerAdapter,
  required Future<void> Function(WidgetTester) interact,
}) async {
  ImportResult? captured;
  final adapter = pickerAdapter ?? _FakeFilePicker(null);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open-button'),
                onPressed: () async {
                  captured = await showDialog<ImportResult>(
                    context: context,
                    builder: (_) => ImportProfilesDialog(
                      pickerAdapter: adapter,
                      backupDecryptor: _directDecrypt,
                    ),
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

  await tester.tap(find.byKey(const Key('open-button')));
  await tester.pumpAndSettle();
  await interact(tester);
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('dialog title is "Import backup"', (tester) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    await _openDialog(
      tester,
      store: store,
      secrets: secrets,
      interact: (t) async {
        expect(find.text('Import backup'), findsOneWidget);
        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );
  });

  testWidgets('v2 end-to-end: pick → passphrase (+checkbox) → applied',
      (tester) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final envelope = await _tinyEnvelope();
    final fake = _FakeFilePicker(PickedFile(
      name: 'backup.mobissh',
      bytes: Uint8List.fromList(utf8.encode(envelope)),
    ));

    final result = await _openDialog(
      tester,
      store: store,
      secrets: secrets,
      pickerAdapter: fake,
      interact: (t) async {
        await t.tap(find.byKey(const Key('import-profiles-pick-file')));
        await t.pumpAndSettle();

        // Pre-decrypt summary names the format without leaking content.
        expect(find.text('Encrypted MobiSSH backup'), findsOneWidget);

        await t.tap(find.byKey(const Key('import-profiles-submit')));
        await t.pumpAndSettle();

        // Passphrase stage: v2 copy + default-OFF restore checkbox.
        expect(
          find.text('Encrypted MobiSSH backup — enter its passphrase.'),
          findsOneWidget,
        );
        final checkboxFinder =
            find.byKey(const Key('import-restore-commands'));
        expect(checkboxFinder, findsOneWidget);
        final checkbox = t.widget<CheckboxListTile>(checkboxFinder);
        expect(checkbox.value, isFalse, reason: 'default OFF');

        await t.enterText(
          find.byKey(const Key('import-profiles-password')),
          _pass,
        );
        await t.pump();

        // The tiny-KDF decrypt is real async work — run it off the fake clock.
        await t.runAsync(() async {
          await t.tap(find.byKey(const Key('import-profiles-submit')));
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            t.binding.scheduleFrame();
            if (find
                .byKey(const Key('import-profiles-dialog'))
                .evaluate()
                .isEmpty) {
              break;
            }
            await t.pump();
          }
        });
      },
    );

    expect(find.byKey(const Key('import-profiles-dialog')), findsNothing);
    expect(result, isNotNull);
    expect(result!.added, 1);

    final loaded = await store.load();
    expect(loaded.single.host, 'h.example');
    expect(loaded.single.vaultId, 'profile-h.example:22:me');
    expect(
      (await secrets.read('profile-h.example:22:me'))?['password'],
      'hunter2hunter2',
    );
  });

  testWidgets('wrong passphrase shows the single generic error, no writes',
      (tester) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());
    final envelope = await _tinyEnvelope();
    final fake = _FakeFilePicker(PickedFile(
      name: 'backup.mobissh',
      bytes: Uint8List.fromList(utf8.encode(envelope)),
    ));

    final result = await _openDialog(
      tester,
      store: store,
      secrets: secrets,
      pickerAdapter: fake,
      interact: (t) async {
        await t.tap(find.byKey(const Key('import-profiles-pick-file')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('import-profiles-submit')));
        await t.pumpAndSettle();
        await t.enterText(
          find.byKey(const Key('import-profiles-password')),
          'not the passphrase',
        );
        await t.pump();
        await t.runAsync(() async {
          await t.tap(find.byKey(const Key('import-profiles-submit')));
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            t.binding.scheduleFrame();
            if (find
                .byKey(const Key('import-profiles-error'))
                .evaluate()
                .isNotEmpty) {
              break;
            }
            await t.pump();
          }
        });
        await t.pump();
        expect(find.text(kBackupGenericError), findsOneWidget);
        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );

    expect(result, isNull);
    expect(await store.load(), isEmpty);
    expect(await secrets.read('profile-h.example:22:me'), isNull);
  });

  testWidgets('v1 vault envelope keeps the legacy copy, no checkbox',
      (tester) async {
    final store = ProfilesStore();
    final secrets = SecretsStore(backend: InMemorySecretsBackend());

    const v1Envelope = '''
{
  "version": 1,
  "profiles": [
    { "host": "h.example", "port": 22, "username": "u", "vaultId": "v1" }
  ],
  "vault": {
    "encrypted": "{\\"v1\\":{\\"iv\\":\\"aa\\",\\"ct\\":\\"bb\\"}}",
    "meta": "{\\"salt\\":\\"cc\\"}"
  }
}
''';
    final fake = _FakeFilePicker(PickedFile(
      name: 'legacy.json',
      bytes: Uint8List.fromList(utf8.encode(v1Envelope)),
    ));

    await _openDialog(
      tester,
      store: store,
      secrets: secrets,
      pickerAdapter: fake,
      interact: (t) async {
        await t.tap(find.byKey(const Key('import-profiles-pick-file')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('import-profiles-submit')));
        await t.pumpAndSettle();

        expect(
          find.text(
            'Legacy encrypted profile export — enter its master password.',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('import-restore-commands')),
          findsNothing,
          reason: 'the commands checkbox is v2-only',
        );
        await t.tap(find.byKey(const Key('import-profiles-cancel')));
      },
    );
  });
}
