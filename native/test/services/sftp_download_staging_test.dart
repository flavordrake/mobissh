// #1160 — pins the path_provider-backed helpers in sftp_download.dart:
//   - [resolveDownloadStagingDir]: app-private `mobissh_downloads` under the
//     application-support dir, falling back to the documents dir when the
//     support dir cannot be resolved (#976 shares it between the UI-side sink
//     and the task-side target);
//   - [TempFileSink.create]: the viewer/share temp file, whose name is the
//     remote basename with path separators stripped (`_sanitizeTemp`) behind a
//     uniqueness stamp.
//
// `flutter test` on the host resolves path_provider to its METHOD-CHANNEL
// implementation (no Dart plugin registrant), so the directories are faked by
// mocking `plugins.flutter.io/path_provider` — the same pattern the widget
// tests use for `mobissh/clipboard`. Importing path_provider_platform_interface
// directly would be a transitive-dependency import and fail `flutter analyze`.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/sftp_download.dart';

const _channel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  /// Per-test answers for the path_provider methods. A missing entry or a
  /// null value makes path_provider throw (MissingPlatformDirectoryException),
  /// which is exactly how an unavailable directory surfaces on device.
  late Map<String, Object?> dirs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobissh_stage_1160_');
    dirs = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final answer = dirs[call.method];
      if (answer is Exception) throw answer;
      return answer;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('resolveDownloadStagingDir', () {
    test('creates mobissh_downloads under the application-support dir',
        () async {
      dirs['getApplicationSupportDirectory'] = '${tmp.path}/support';
      dirs['getApplicationDocumentsDirectory'] = '${tmp.path}/docs';

      final dir = await resolveDownloadStagingDir();

      expect(dir.path, '${tmp.path}/support/mobissh_downloads');
      expect(await dir.exists(), isTrue);
      expect(await Directory('${tmp.path}/docs').exists(), isFalse,
          reason: 'the documents dir is not touched when support resolves');
    });

    test('falls back to the documents dir when the support dir is unavailable',
        () async {
      dirs['getApplicationSupportDirectory'] = null;
      dirs['getApplicationDocumentsDirectory'] = '${tmp.path}/docs';

      final dir = await resolveDownloadStagingDir();

      expect(dir.path, '${tmp.path}/docs/mobissh_downloads');
      expect(await dir.exists(), isTrue);
    });

    test('falls back to the documents dir when the support lookup throws',
        () async {
      dirs['getApplicationSupportDirectory'] =
          PlatformException(code: 'NO_SUPPORT_DIR');
      dirs['getApplicationDocumentsDirectory'] = '${tmp.path}/docs';

      final dir = await resolveDownloadStagingDir();

      expect(dir.path, '${tmp.path}/docs/mobissh_downloads');
      expect(await dir.exists(), isTrue);
    });

    test('is idempotent: an existing staging dir and its files survive',
        () async {
      dirs['getApplicationSupportDirectory'] = '${tmp.path}/support';
      final first = await resolveDownloadStagingDir();
      final inFlight = File('${first.path}/partial.bin');
      await inFlight.writeAsString('in flight', flush: true);

      final second = await resolveDownloadStagingDir();

      expect(second.path, first.path);
      expect(await inFlight.readAsString(), 'in flight');
    });

    test('propagates when neither directory can be resolved', () async {
      // Both lookups unavailable: there is no third fallback, the caller sees
      // the documents-dir failure rather than a silent bogus path.
      await expectLater(
        resolveDownloadStagingDir(),
        throwsA(isA<Exception>()),
      );
    });

    test('does not fall back when the support dir resolves but cannot be '
        'created', () async {
      // A regular file where the support dir should be: mkdir -p fails. The
      // fallback covers an unresolvable dir only, so this surfaces as an error.
      await File('${tmp.path}/blocker').writeAsString('not a dir');
      dirs['getApplicationSupportDirectory'] = '${tmp.path}/blocker/support';
      dirs['getApplicationDocumentsDirectory'] = '${tmp.path}/docs';

      await expectLater(
        resolveDownloadStagingDir(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Directory('${tmp.path}/docs').exists(), isFalse);
    });
  });

  group('production factories stage under the resolved dir', () {
    test('defaultDownloadTargetFactory puts the task-side target in '
        'support/mobissh_downloads', () async {
      dirs['getApplicationSupportDirectory'] = '${tmp.path}/support';

      final target = await defaultDownloadTargetFactory('nested/dir/file.bin');

      expect(
        target.localPath,
        '${tmp.path}/support/mobissh_downloads/file.bin',
      );
      expect(await File(target.localPath).exists(), isFalse,
          reason: 'the task opens the file itself; the factory only clears it');
    });

    test('AppDownloadsSink.create stages the UI-side sink in the same dir',
        () async {
      dirs['getApplicationSupportDirectory'] = '${tmp.path}/support';

      final sink = await AppDownloadsSink.create('nested/file.bin');

      expect(sink.path, '${tmp.path}/support/mobissh_downloads/file.bin');
      expect(await File(sink.path).exists(), isTrue,
          reason: 'the sink opens the staging file up front');
      await sink.abort();
    });
  });

  group('TempFileSink.create (_sanitizeTemp)', () {
    Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

    setUp(() {
      dirs['getTemporaryDirectory'] = '${tmp.path}/cache';
    });

    test('lands in <temp>/mobissh_pdf as <stamp>-<basename>', () async {
      final sink = await TempFileSink.create('remote/dir/manual.pdf');

      expect(sink.file.parent.path, '${tmp.path}/cache/mobissh_pdf');
      final name = sink.file.uri.pathSegments.last;
      expect(name, endsWith('-manual.pdf'));
      expect(
        RegExp(r'^\d+-manual\.pdf$').hasMatch(name),
        isTrue,
        reason: 'numeric stamp prefix keeps repeated previews apart',
      );
      await sink.abort();
    });

    test('strips backslash separators too', () async {
      final sink = await TempFileSink.create(r'C:\share\notes.pdf');

      expect(sink.file.uri.pathSegments.last, endsWith('-notes.pdf'));
      expect(sink.file.uri.pathSegments.last, isNot(contains(r'\')));
      await sink.abort();
    });

    test('an empty basename falls back to preview.pdf', () async {
      final trailing = await TempFileSink.create('remote/dir/');
      final empty = await TempFileSink.create('');

      expect(trailing.file.uri.pathSegments.last, endsWith('-preview.pdf'));
      expect(empty.file.uri.pathSegments.last, endsWith('-preview.pdf'));
      await trailing.abort();
      await empty.abort();
    });

    test('honours the subdir override used by viewer Share staging (#1038)',
        () async {
      final sink = await TempFileSink.create(
        'photo.png',
        subdir: 'mobissh_share',
      );

      expect(sink.file.parent.path, '${tmp.path}/cache/mobissh_share');
      expect(await sink.file.parent.exists(), isTrue);
      await sink.abort();
    });

    test('two sinks for the same remote name get distinct files', () async {
      final a = await TempFileSink.create('same.pdf');
      final b = await TempFileSink.create('same.pdf');

      expect(a.file.path, isNot(b.file.path));
      expect(await a.file.exists(), isTrue);
      expect(await b.file.exists(), isTrue);
      await a.abort();
      await b.abort();
    });

    test('finish returns the temp path and keeps the file for the caller',
        () async {
      final sink = await TempFileSink.create('doc.pdf');
      final data = bytes('%PDF-1.4 stub');
      await sink.addChunk(data, 0);

      final path = await sink.finish(expectedTotal: data.length);

      expect(path, sink.file.path);
      expect(await sink.file.readAsBytes(), equals(data),
          reason: 'the viewer deletes the temp file itself when it closes');
    });

    test('create fails loudly when the temp dir is unavailable', () async {
      dirs['getTemporaryDirectory'] = null;

      await expectLater(
        TempFileSink.create('doc.pdf'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
