// #1160 — pins [AppDownloadTarget], the TASK-SIDE download destination (#976).
//
// The task isolate streams the remote file straight into [localPath]; the UI
// then calls [publish] (move into public Downloads) or [abort] (drop the
// partial). These tests pin the Dart-side contract around that hand-off, the
// same way sftp_download_publish_test.dart pins the UI-side [AppDownloadsSink]:
//   - createInDir clears a stale partial and confines the name to the dir,
//   - publish success drops the staging copy and reports the published location,
//   - publish failure keeps the completed file and reports its path,
//   - abort deletes the partial and is safe to repeat.
// The MediaStore copy itself is device-validated, not unit-tested.
//
// Uses the [AppDownloadTarget.createInDir] seam so staging happens in a real
// temp dir without a path_provider platform channel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/sftp_download.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobissh_dl_1160_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Simulates the task isolate having streamed [content] into the target.
  Future<File> streamInto(AppDownloadTarget target, String content) async {
    final file = File(target.localPath);
    await file.writeAsString(content, flush: true);
    return file;
  }

  Future<String> neverPublish(String src, String name, String? mime) async =>
      throw Exception('no platform channel');

  group('createInDir', () {
    test('stages under the given dir with the sanitized basename', () async {
      final target = await AppDownloadTarget.createInDir(
        tmp,
        '../../etc/evil\\..\\passwd',
      );

      expect(target.localPath, '${tmp.path}/passwd',
          reason: 'separators are stripped so the name cannot escape the dir');
    });

    test('removes a stale partial from a prior attempt before handing over',
        () async {
      final stale = File('${tmp.path}/big.iso');
      await stale.writeAsString('leftover partial bytes', flush: true);

      final target = await AppDownloadTarget.createInDir(tmp, 'big.iso');

      expect(target.localPath, stale.path);
      expect(await stale.exists(), isFalse,
          reason: "the task's openWrite must start on a clean file");
    });

    test('creates the staging dir when it does not exist yet', () async {
      final nested = Directory('${tmp.path}/not/yet/here');
      expect(await nested.exists(), isFalse);

      final target = await AppDownloadTarget.createInDir(nested, 'a.bin');

      expect(await nested.exists(), isTrue);
      expect(target.localPath, '${nested.path}/a.bin');
    });
  });

  group('publish', () {
    test('hands the staging file to the publisher and drops the staging copy',
        () async {
      String? gotSrc;
      String? gotName;
      String? gotMime = 'unset';
      final target = await AppDownloadTarget.createInDir(
        tmp,
        'report.pdf',
        publisher: (src, name, mime) async {
          gotSrc = src;
          gotName = name;
          gotMime = mime;
          return 'Downloads/report.pdf';
        },
      );
      final staged = await streamInto(target, 'completed download');

      final location = await target.publish();

      expect(location, 'Downloads/report.pdf');
      expect(gotSrc, target.localPath,
          reason: 'publisher receives the completed staging file path');
      expect(gotName, 'report.pdf');
      expect(gotMime, isNull, reason: 'task-side target passes no mime hint');
      expect(await staged.exists(), isFalse,
          reason: 'staging copy is removed once published to Downloads');
    });

    test('keeps the completed file and returns its path when publishing fails',
        () async {
      final target = await AppDownloadTarget.createInDir(
        tmp,
        'keepme.bin',
        publisher: neverPublish,
      );
      final staged = await streamInto(target, 'payload that must not be lost');

      final location = await target.publish();

      expect(location, target.localPath,
          reason: 'fallback reports the staging path so the file is findable');
      expect(await staged.exists(), isTrue,
          reason: 'a completed download is never deleted on publish failure');
      expect(await staged.readAsString(), 'payload that must not be lost');
    });

    test('still reports the published location if deleting the staging copy '
        'fails', () async {
      final target = await AppDownloadTarget.createInDir(
        tmp,
        'gone.bin',
        publisher: (src, name, mime) async {
          // Publisher "moved" the file itself: nothing left to delete.
          await File(src).delete();
          return 'Downloads/gone.bin';
        },
      );
      await streamInto(target, 'moved by publisher');

      expect(await target.publish(), 'Downloads/gone.bin');
      expect(await File(target.localPath).exists(), isFalse);
    });
  });

  group('abort', () {
    test('deletes the partial file', () async {
      final target = await AppDownloadTarget.createInDir(tmp, 'partial.bin');
      final staged = await streamInto(target, 'half a file');

      await target.abort();

      expect(await staged.exists(), isFalse);
    });

    test('is idempotent and a no-op when nothing was ever written', () async {
      final target = await AppDownloadTarget.createInDir(tmp, 'never.bin');
      expect(await File(target.localPath).exists(), isFalse);

      await target.abort();
      await target.abort();

      expect(await File(target.localPath).exists(), isFalse);
      expect(await tmp.exists(), isTrue,
          reason: 'abort only touches the staging file, never the dir');
    });

    test('after a failed publish, abort removes the retained file (user '
        'cancel wins over the fallback)', () async {
      final target = await AppDownloadTarget.createInDir(
        tmp,
        'retained.bin',
        publisher: neverPublish,
      );
      final staged = await streamInto(target, 'kept by fallback');
      expect(await target.publish(), target.localPath);
      expect(await staged.exists(), isTrue);

      await target.abort();

      expect(await staged.exists(), isFalse);
    });

    test('a fresh target for the same name after abort starts clean',
        () async {
      final first = await AppDownloadTarget.createInDir(tmp, 'again.bin');
      await streamInto(first, 'first attempt');
      await first.abort();

      final second = await AppDownloadTarget.createInDir(tmp, 'again.bin');

      expect(second.localPath, first.localPath);
      expect(await File(second.localPath).exists(), isFalse);
    });
  });

  test('localPath is stable across the publish/abort lifecycle', () async {
    final target = await AppDownloadTarget.createInDir(
      tmp,
      'stable.bin',
      publisher: (src, name, mime) async => 'Downloads/$name',
    );
    final before = target.localPath;
    await streamInto(target, 'x');
    await target.publish();
    await target.abort();

    expect(target.localPath, before,
        reason: 'the UI resolves the path up front and reuses it for the '
            'done/error events');
  });
}
