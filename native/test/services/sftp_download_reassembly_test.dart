// Regression test for #591 — SFTP/PDF download corrupts large files when
// chunks are written without honoring their byte offset.
//
// The download path carries a byte `offset` for every chunk
// (SftpDownloadChunkEvent.offset) but the destination sink historically
// appended chunks in *arrival order*, assuming in-order delivery. A reordered
// or partial chunk therefore produced a corrupt file. This test drives the sink
// with chunks delivered OUT OF ORDER and asserts the reassembled file is
// byte-for-byte identical to the source (content digest + exact byte compare),
// which fails on the append-in-arrival-order implementation.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/sftp_download.dart';

/// Byte-exact comparison via a content digest. Avoids pulling in the `crypto`
/// package (only a transitive dep): a simple FNV-1a-style rolling hash over
/// every byte detects any reorder/truncation/overlap corruption, and we also
/// assert exact length + a direct byte equality.
int _digest(List<int> bytes) {
  var h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
  for (final b in bytes) {
    h = (h ^ b) & 0x7fffffffffffffff;
    h = (h * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return h;
}

/// Split [source] into fixed-size chunks paired with their byte offset.
List<({Uint8List bytes, int offset})> _chunkify(Uint8List source, int size) {
  final out = <({Uint8List bytes, int offset})>[];
  for (var o = 0; o < source.length; o += size) {
    final end = min(o + size, source.length);
    out.add((bytes: Uint8List.sublistView(source, o, end), offset: o));
  }
  return out;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobissh_dl_591_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Source large enough to need many chunks: 256 KiB of pseudo-random bytes.
  Uint8List makeSource() {
    final rng = Random(0xC0FFEE);
    final b = Uint8List(256 * 1024);
    for (var i = 0; i < b.length; i++) {
      b[i] = rng.nextInt(256);
    }
    return b;
  }

  test(
    'reassembles a multi-chunk file byte-exact when chunks arrive in order',
    () async {
      final source = makeSource();
      final file = File('${tmp.path}/in-order.bin');
      final sink = await OffsetFileSink.create(file);

      for (final c in _chunkify(source, 64 * 1024)) {
        await sink.addChunk(c.bytes, c.offset);
      }
      await sink.finish(expectedTotal: source.length);

      final written = await file.readAsBytes();
      expect(written.length, source.length);
      expect(_digest(written), _digest(source));
      expect(written, equals(source));
    },
  );

  test('reassembles a multi-chunk file byte-exact when chunks arrive REORDERED '
      '(the #591 corruption case)', () async {
    final source = makeSource();
    final file = File('${tmp.path}/reordered.bin');
    final sink = await OffsetFileSink.create(file);

    final chunks = _chunkify(source, 64 * 1024);
    // Shuffle so chunks are delivered out of arrival order — exactly the
    // condition that corrupts an append-only sink.
    chunks.shuffle(Random(42));
    for (final c in chunks) {
      await sink.addChunk(c.bytes, c.offset);
    }
    await sink.finish(expectedTotal: source.length);

    final written = await file.readAsBytes();
    expect(written.length, source.length);
    expect(
      _digest(written),
      _digest(source),
      reason: 'reordered chunks must reassemble byte-for-byte by offset',
    );
    expect(written, equals(source));
  });

  test('finish() rejects a truncated transfer (length verification)', () async {
    final source = makeSource();
    final file = File('${tmp.path}/short.bin');
    final sink = await OffsetFileSink.create(file);

    // Deliver everything except the last chunk.
    final chunks = _chunkify(source, 64 * 1024);
    for (final c in chunks.sublist(0, chunks.length - 1)) {
      await sink.addChunk(c.bytes, c.offset);
    }

    expect(
      () => sink.finish(expectedTotal: source.length),
      throwsA(isA<Exception>()),
      reason: 'a transfer missing bytes must not be reported as complete',
    );
  });
}
