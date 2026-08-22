// Export-backup dialog (#1124). Locks:
// - passphrase mismatch blocks (no save call),
// - <12-char passphrase blocks with the policy message,
// - success hands the save adapter ONLY envelope JSON (outer-field allowlist,
//   no secret canary anywhere in the saved bytes) and toasts the counts,
// - cancel/dismiss never calls the adapter,
// - a payload failure (unreadable secrets) surfaces its error in-dialog.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/storage/backup.dart';
import 'package:mobissh/storage/backup_payload.dart';
import 'package:mobissh/ui/export_backup_dialog.dart';

const _tinyKdf = BackupKdfParams(mKiB: 64, t: 1, p: 1);
const _canary = 'CANARY-secret-hunter2';
const _goodPass = 'correct horse battery';

class _FakeSaveAdapter implements BackupSaveAdapter {
  final List<({String fileName, Uint8List bytes})> calls = [];
  bool saveResult = true;

  @override
  Future<bool> createDocument({
    required String fileName,
    required Uint8List bytes,
  }) async {
    calls.add((fileName: fileName, bytes: bytes));
    return saveResult;
  }
}

Map<String, Object?> _payload() => <String, Object?>{
      'payloadVersion': 1,
      'createdAt': '2026-08-22T12:00:00.000Z',
      'appVersion': 'test+1',
      'profiles': [
        {'host': 'h1.example', 'port': 22, 'username': 'u1'},
        {'host': 'h2.example', 'port': 22, 'username': 'u2'},
      ],
      'keys': [
        {'id': 'lib1', 'name': 'laptop key'},
      ],
      'secrets': {
        'vault-a': {'password': _canary},
      },
    };

BackupPayloadResult _okResult() => BackupPayloadResult.success(
      payload: _payload(),
      profileCount: 2,
      keyCount: 1,
    );

// Real (tiny-KDF) encryption injected in place of the production
// Isolate.run + default-KDF path, so tests assert REAL envelope framing
// without the 19 MiB Argon2 cost.
Future<String> _tinyEncryptor(Map<String, Object?> payload, String pass) =>
    encryptBackupEnvelope(payload: payload, passphrase: pass, kdf: _tinyKdf);

/// Clean preflight matching [_okResult] — the default so pre-preflight tests
/// keep their behavior (passphrase fields present after settle).
Future<BackupPreflight> _cleanPreflight() async => const BackupPreflight(
      profileCount: 2,
      keyCount: 1,
      readableSecretCount: 1,
      unreadableLabels: <String>[],
    );

Future<void> _pumpHost(
  WidgetTester tester, {
  required _FakeSaveAdapter adapter,
  BackupPayloadBuilder? payloadBuilder,
  BackupPreflightRunner? preflight,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                showExportBackupDialog(
                  context,
                  payloadBuilder: payloadBuilder ??
                      ({bool allowMissing = false}) async => _okResult(),
                  preflight: preflight ?? _cleanPreflight,
                  encryptor: _tinyEncryptor,
                  saveAdapter: adapter,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('export-backup-dialog')), findsOneWidget);
}

Future<void> _enterPassphrases(
  WidgetTester tester,
  String pass,
  String confirm,
) async {
  await tester.enterText(
      find.byKey(const Key('export-backup-passphrase')), pass);
  await tester.enterText(find.byKey(const Key('export-backup-confirm')), confirm);
  await tester.pump();
}

Future<void> _tapSubmit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('export-backup-submit')));
  await tester.pump();
}

/// Drain REAL async work (Argon2id runs on real futures that escape the fake
/// clock — pump() alone never settles them; see the fakeasync gotcha memory).
Future<void> _settleReal(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('passphrase mismatch blocks the export', (tester) async {
    final adapter = _FakeSaveAdapter();
    await _pumpHost(tester, adapter: adapter);
    await _enterPassphrases(tester, _goodPass, 'different horse battery');
    await _tapSubmit(tester);
    expect(find.byKey(const Key('export-backup-error')), findsOneWidget);
    expect(find.textContaining('match'), findsOneWidget);
    expect(adapter.calls, isEmpty);
    expect(find.byKey(const Key('export-backup-dialog')), findsOneWidget);
  });

  testWidgets('short passphrase blocks with the policy message', (tester) async {
    final adapter = _FakeSaveAdapter();
    await _pumpHost(tester, adapter: adapter);
    await _enterPassphrases(tester, 'short', 'short');
    await _tapSubmit(tester);
    expect(find.byKey(const Key('export-backup-error')), findsOneWidget);
    expect(find.textContaining('at least 12 characters'), findsOneWidget);
    expect(adapter.calls, isEmpty);
  });

  testWidgets('success hands the adapter ONLY envelope JSON + toasts counts',
      (tester) async {
    final adapter = _FakeSaveAdapter();
    await _pumpHost(tester, adapter: adapter);
    await _enterPassphrases(tester, _goodPass, _goodPass);
    await _tapSubmit(tester);
    await _settleReal(tester, () => adapter.calls.isNotEmpty);

    expect(adapter.calls, hasLength(1));
    final call = adapter.calls.single;
    expect(
      call.fileName,
      matches(RegExp(r'^mobissh-backup-\d{8}-\d{6}\.mobissh$')),
    );
    final savedText = utf8.decode(call.bytes);
    // The save seam must only ever see ciphertext: outer allowlist, no canary.
    expect(savedText, isNot(contains(_canary)));
    expect(savedText, isNot(contains('h1.example')));
    final outer = jsonDecode(savedText) as Map<String, dynamic>;
    expect(
      outer.keys.toSet(),
      {'format', 'version', 'kdf', 'cipher', 'ciphertext'},
    );
    expect(outer['format'], 'mobissh-backup');

    // Dialog closed + toast with the counts.
    expect(find.byKey(const Key('export-backup-dialog')), findsNothing);
    expect(find.textContaining('Backup saved (2 profiles, 1 keys)'),
        findsOneWidget);
  });

  testWidgets('cancel writes nothing', (tester) async {
    final adapter = _FakeSaveAdapter();
    await _pumpHost(tester, adapter: adapter);
    await _enterPassphrases(tester, _goodPass, _goodPass);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('export-backup-dialog')), findsNothing);
    expect(adapter.calls, isEmpty);
  });

  testWidgets('unreadable-secrets payload failure surfaces in-dialog',
      (tester) async {
    final adapter = _FakeSaveAdapter();
    await _pumpHost(
      tester,
      adapter: adapter,
      payloadBuilder: ({bool allowMissing = false}) async =>
          const BackupPayloadResult.failure(
        error: '2 stored secrets could not be read — backup not created.',
        unreadableSecretCount: 2,
      ),
    );
    await _enterPassphrases(tester, _goodPass, _goodPass);
    await _tapSubmit(tester);
    await _settleReal(
      tester,
      () => find
          .byKey(const Key('export-backup-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('export-backup-error')), findsOneWidget);
    expect(find.textContaining('2 stored secrets'), findsOneWidget);
    expect(adapter.calls, isEmpty);
    expect(find.byKey(const Key('export-backup-dialog')), findsOneWidget);
  });

  testWidgets(
      'preflight gates the passphrase: unreadable entries hide the fields '
      'until the skip opt-in', (tester) async {
    final adapter = _FakeSaveAdapter();
    bool? capturedAllowMissing;
    await _pumpHost(
      tester,
      adapter: adapter,
      preflight: () async => const BackupPreflight(
        profileCount: 3,
        keyCount: 1,
        readableSecretCount: 1,
        unreadableLabels: ['NV-dev', 'fd-dev'],
      ),
      payloadBuilder: ({bool allowMissing = false}) async {
        capturedAllowMissing = allowMissing;
        return BackupPayloadResult.success(
          payload: _payload(),
          profileCount: 3,
          keyCount: 1,
          omittedLabels: const ['NV-dev', 'fd-dev'],
        );
      },
    );

    // Owner rule #1: NO passphrase entry before the export is known
    // buildable — the unreadable notice + opt-in show instead, submit off.
    expect(find.byKey(const Key('export-backup-preflight-unreadable')),
        findsOneWidget);
    expect(find.textContaining('NV-dev'), findsOneWidget);
    expect(find.byKey(const Key('export-backup-passphrase')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('export-backup-submit')))
          .onPressed,
      isNull,
      reason: 'submit disabled until the export is buildable',
    );

    // Owner rule #2: explicit "export anyway" reveals the passphrase stage.
    await tester.tap(find.byKey(const Key('export-skip-unreadable')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('export-backup-passphrase')), findsOneWidget);

    await _enterPassphrases(tester, _goodPass, _goodPass);
    await _tapSubmit(tester);
    await _settleReal(tester, () => adapter.calls.isNotEmpty);
    expect(capturedAllowMissing, isTrue,
        reason: 'the opt-in must reach the payload builder');
    expect(adapter.calls, hasLength(1));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 credentials skipped'), findsOneWidget);
  });

  testWidgets('clean preflight shows the ready line and the fields directly',
      (tester) async {
    final adapter = _FakeSaveAdapter();
    await _pumpHost(tester, adapter: adapter);
    expect(find.byKey(const Key('export-backup-preflight-ok')), findsOneWidget);
    expect(find.byKey(const Key('export-backup-passphrase')), findsOneWidget);
    expect(find.byKey(const Key('export-skip-unreadable')), findsNothing);
  });
}
