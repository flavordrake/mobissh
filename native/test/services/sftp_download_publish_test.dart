// #559 — SFTP downloads must land in the user-visible public Downloads folder.
//
// [AppDownloadsSink] streams chunks into an app-private staging file, then on
// finish() hands the completed file to the native publisher, which copies it
// into the shared Downloads collection (MediaStore on API 29+). These tests
// verify the Dart-side contract around that hand-off — the publisher receives
// the finished staging file, the staging copy is cleaned up on success, and a
// publish failure falls back to keeping the staging file (a download is never
// lost). The actual MediaStore copy is device-validated, not unit-tested.
//
// Uses the [AppDownloadsSink.createInDir] test seam so staging happens in a real
// temp dir without a path_provider platform channel.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/sftp_download.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobissh_dl_559_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  test('publishes the finished file to Downloads and removes the staging copy',
      () async {
    String? gotSrc;
    String? gotName;
    final sink = await AppDownloadsSink.createInDir(
      tmp,
      'report.pdf',
      publisher: (src, name, mime) async {
        gotSrc = src;
        gotName = name;
        return 'Downloads/report.pdf';
      },
    );
    final stagingPath = sink.path;

    final data = bytes('hello downloads');
    await sink.addChunk(data, 0);
    final location = await sink.finish(expectedTotal: data.length);

    expect(location, 'Downloads/report.pdf');
    expect(gotName, 'report.pdf');
    expect(gotSrc, stagingPath,
        reason: 'publisher receives the completed staging file path');
    expect(await File(stagingPath).exists(), isFalse,
        reason: 'staging copy is removed once published to Downloads');
  });

  test('keeps the staging file and returns its path when publishing fails',
      () async {
    final sink = await AppDownloadsSink.createInDir(
      tmp,
      'keepme.bin',
      publisher: (src, name, mime) async =>
          throw Exception('no platform channel'),
    );
    final stagingPath = sink.path;

    final data = bytes('payload that must not be lost');
    await sink.addChunk(data, 0);
    final location = await sink.finish(expectedTotal: data.length);

    expect(location, stagingPath,
        reason: 'fallback reports the staging path so the file is findable');
    expect(await File(stagingPath).exists(), isTrue,
        reason: 'a completed download is never deleted on publish failure');
    expect(await File(stagingPath).readAsBytes(), equals(data));
  });

  test('a truncated transfer never reaches the publisher', () async {
    var published = false;
    final sink = await AppDownloadsSink.createInDir(
      tmp,
      'short.bin',
      publisher: (src, name, mime) async {
        published = true;
        return 'Downloads/short.bin';
      },
    );

    await sink.addChunk(bytes('only some'), 0);

    // expectedTotal exceeds what was written → length verification throws.
    await expectLater(
      sink.finish(expectedTotal: 9999),
      throwsA(isA<Exception>()),
    );
    expect(published, isFalse,
        reason: 'a corrupt/short download must not be published as complete');
  });
}
