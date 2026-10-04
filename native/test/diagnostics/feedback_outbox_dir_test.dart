// #1271 (0.1.13 security review): the bug-report outbox holds screenshots and
// terminal traces. On Android it must live under getNoBackupFilesDir() — the
// app documents dir (`app_flutter/`) is included in Auto Backup and
// device-to-device transfer — and reports saved there by an older build are
// moved over once, so none is lost.
//
// path_provider and the app's `mobissh/paths` channel are faked by mocking
// their method channels (the sftp_download_staging_test pattern).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/feedback_outbox.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _paths = MethodChannel('mobissh/paths');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String? noBackup;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobissh_outbox_dir_');
    noBackup = '${tmp.path}/no_backup';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathProvider, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return '${tmp.path}/app_flutter';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_paths, (call) async {
      if (call.method == 'noBackupDir') return noBackup;
      return null;
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathProvider, null);
    messenger.setMockMethodCallHandler(_paths, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('Android: the outbox is under the no-backup dir', () async {
    final d = await FeedbackOutbox.resolveDefaultDir(android: true);
    expect(d, isNotNull);
    expect(d!.path, '${tmp.path}/no_backup/feedback-outbox');
  });

  test('Android: reports in the old backed-up dir are moved, once', () async {
    final legacy = Directory('${tmp.path}/app_flutter/feedback-outbox')
      ..createSync(recursive: true);
    File('${legacy.path}/report-00000000000000001-0000.json')
        .writeAsStringSync('{"comment":"pending"}');
    File('${legacy.path}/report-00000000000000002-0000.rejected')
        .writeAsStringSync('{"comment":"rejected"}');

    final d = await FeedbackOutbox.resolveDefaultDir(android: true);

    final moved = d!
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList()
      ..sort();
    expect(moved, [
      'report-00000000000000001-0000.json',
      'report-00000000000000002-0000.rejected',
    ]);
    expect(
      File('${d.path}/report-00000000000000001-0000.json').readAsStringSync(),
      '{"comment":"pending"}',
    );
    expect(legacy.existsSync(), isFalse,
        reason: 'nothing may stay behind in the backed-up dir');

    // A second resolve has nothing to move and keeps what is there.
    final again = await FeedbackOutbox.resolveDefaultDir(android: true);
    expect(again!.listSync().length, 2);
  });

  test('Android: no no-backup dir → no outbox (never the backed-up dir)',
      () async {
    noBackup = null;
    final d = await FeedbackOutbox.resolveDefaultDir(android: true);
    expect(d, isNull);
  });

  test('other platforms keep the documents dir', () async {
    final d = await FeedbackOutbox.resolveDefaultDir(android: false);
    expect(d!.path, '${tmp.path}/app_flutter/feedback-outbox');
  });
}
