// SFTP download destination seam (#559, #591).
//
// The task isolate streams file chunks across IPC (base64); the UI assembles
// them into a destination on the device. This file owns the *destination*
// abstraction so the chunk-assembly logic is reusable and the storage backend
// is swappable:
//
//   - [AppDownloadsSink] streams chunks into an app-private *staging* file,
//     then on [finish] publishes the completed file into the user-visible
//     shared Downloads collection via the native `mobissh/downloads` channel
//     (MediaStore on API 29+, the public Downloads dir on older devices —
//     see downloads_publisher.dart / MainActivity.kt). The file lands where
//     the system file manager's "Downloads" shows it. If publishing fails the
//     staging file is kept and its path returned, so a download is never lost.
//
// Keeping the assembly here (not in the widget) means Slice 2's folder
// download can reuse it per-file.
//
// #591 (data corruption): chunks MUST be written at their byte offset, not
// appended in arrival order. Each [SftpDownloadChunkEvent] carries an `offset`;
// the gateway can deliver them reordered (and a fire-and-forget write can race
// them), so an append-only sink silently corrupts any multi-chunk file. The
// sinks below write each chunk at its offset via a [RandomAccessFile] and
// [finish] verifies the total length so a truncated transfer can't be reported
// as a success.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'downloads_publisher.dart';

/// A destination for a single downloaded file. Chunks arrive from the task
/// isolate keyed by their byte [offset] (NOT guaranteed in order); [addChunk]
/// writes each at its offset, [finish] verifies the total length, flushes +
/// closes, and returns a human-readable location for the success snackbar.
abstract class FileDownloadSink {
  /// Write [bytes] at byte [offset]. Safe to call out of order.
  Future<void> addChunk(Uint8List bytes, int offset);

  /// Flush + close. [expectedTotal], when known (the server-reported size /
  /// the `done` event's totalBytes), is verified against the bytes actually
  /// written; a mismatch throws so a corrupt/truncated file is never reported
  /// as a successful download. Returns a display path / URI.
  Future<String> finish({int? expectedTotal});

  /// Abort + clean up a partial file (called on error / cancel).
  Future<void> abort();
}

/// Resolves the destination sink for a download. Injected into the browser so
/// widget tests substitute an in-memory sink (no real filesystem). Production
/// resolves to an [AppDownloadsSink].
typedef DownloadSinkFactory =
    Future<FileDownloadSink> Function(String fileName);

/// Production factory: app-scoped Downloads directory via path_provider.
Future<FileDownloadSink> defaultDownloadSinkFactory(String fileName) async {
  return AppDownloadsSink.create(fileName);
}

/// Resolves the destination sink for downloads. Overridden in widget/emulator
/// tests to avoid touching the real filesystem; production uses the Downloads
/// pipeline above. Lives here (not in the browser) since #1038: the browser
/// AND every viewer's Download action share this seam — one override covers
/// both. Re-exported by file_browser_screen.dart for existing importers.
final downloadSinkFactoryProvider = Provider<DownloadSinkFactory>(
  (ref) => defaultDownloadSinkFactory,
);

/// Offset-honoring core sink: writes chunks at their byte offset into a given
/// [File] via a [RandomAccessFile], tracks the highest end position written,
/// and verifies the total length on [finish]. Both [AppDownloadsSink] and
/// [TempFileSink] resolve a destination directory then delegate here, so the
/// reassembly logic is shared and unit-testable without path_provider (pass a
/// plain temp [File]).
class OffsetFileSink implements FileDownloadSink {
  OffsetFileSink._(this.file, this._raf);

  /// The file being assembled.
  final File file;
  final RandomAccessFile _raf;

  /// One byte past the highest offset written — the assembled length so far.
  int _highWater = 0;

  /// Open [file] for random-access writing (truncating any prior content).
  static Future<OffsetFileSink> create(File file) async {
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    // WRITE mode truncates to empty, giving us a clean canvas to seek into.
    final raf = await file.open(mode: FileMode.write);
    return OffsetFileSink._(file, raf);
  }

  @override
  Future<void> addChunk(Uint8List bytes, int offset) async {
    if (bytes.isEmpty) return;
    await _raf.setPosition(offset);
    await _raf.writeFrom(bytes);
    final end = offset + bytes.length;
    if (end > _highWater) _highWater = end;
  }

  @override
  Future<String> finish({int? expectedTotal}) async {
    await _raf.flush();
    await _raf.close();
    if (expectedTotal != null && _highWater != expectedTotal) {
      // The transfer is short (or over-long): do NOT present a corrupt file as
      // a completed download. Clean up and surface the mismatch.
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        /* best-effort */
      }
      throw Exception(
        'Download incomplete: wrote $_highWater of $expectedTotal bytes',
      );
    }
    return file.path;
  }

  @override
  Future<void> abort() async {
    try {
      await _raf.close();
    } catch (_) {
      /* ignore */
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* ignore */
    }
  }
}

/// Streams chunks into an app-private staging file, then on [finish] publishes
/// the completed file into the user-visible public Downloads collection via the
/// native `mobissh/downloads` channel ([platformPublishToDownloads]). Offset-
/// honoring assembly + length verification are delegated to [OffsetFileSink];
/// publishing is injectable so tests substitute a fake.
///
/// If publishing throws (non-Android host, MediaStore failure), the staging
/// file is kept and its path returned — a completed download is never lost,
/// it just stays in app-private storage.
class AppDownloadsSink implements FileDownloadSink {
  AppDownloadsSink._(this._inner, this._fileName, this._publish);

  final OffsetFileSink _inner;
  final String _fileName;
  final DownloadsPublisher _publish;

  /// The staging file path (for tests / callers that need it).
  String get path => _inner.file.path;

  static Future<AppDownloadsSink> create(
    String fileName, {
    DownloadsPublisher? publisher,
  }) async {
    final dir = await _resolveStagingDir();
    return createInDir(dir, fileName, publisher: publisher);
  }

  /// Test seam: stage into an explicit [dir] (a real temp dir in tests) so the
  /// publish/cleanup/fallback contract is verifiable without path_provider.
  static Future<AppDownloadsSink> createInDir(
    Directory dir,
    String fileName, {
    DownloadsPublisher? publisher,
  }) async {
    final safeName = _sanitize(fileName);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$safeName');
    final inner = await OffsetFileSink.create(file);
    return AppDownloadsSink._(
      inner,
      safeName,
      publisher ?? platformPublishToDownloads,
    );
  }

  /// App-private staging directory for in-flight downloads. Not user-visible;
  /// the file is moved into public Downloads on [finish].
  static Future<Directory> _resolveStagingDir() async {
    Directory base;
    try {
      base =
          await getApplicationSupportDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/mobissh_downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Strip path separators so a remote basename can't escape the target dir.
  static String _sanitize(String name) {
    final base = name.split('/').last.split('\\').last;
    return base.isEmpty ? 'download' : base;
  }

  @override
  Future<void> addChunk(Uint8List bytes, int offset) =>
      _inner.addChunk(bytes, offset);

  @override
  Future<String> finish({int? expectedTotal}) async {
    // Verify length first; this throws (and deletes) on a truncated transfer.
    final stagingPath = await _inner.finish(expectedTotal: expectedTotal);
    try {
      final location = await _publish(stagingPath, _fileName, null);
      // Published into public Downloads — drop the staging copy.
      try {
        final staged = File(stagingPath);
        if (await staged.exists()) await staged.delete();
      } catch (_) {
        /* best-effort cleanup */
      }
      return location;
    } catch (_) {
      // Publishing unavailable/failed: keep the completed staging file so the
      // download isn't lost, and report its path.
      return stagingPath;
    }
  }

  @override
  Future<void> abort() => _inner.abort();
}

/// Writes a download into a private app TEMP directory rather than Downloads.
/// Used by the in-app PDF viewer (#557): the file is fetched to temp, rendered,
/// then deleted on close; and by the viewer Share staging (#1038, [subdir]
/// `mobissh_share`). [finish] returns the temp file path; [file] exposes
/// the [File] so the caller can delete it explicitly. Delegates offset-honoring
/// assembly + length verification to [OffsetFileSink].
class TempFileSink implements FileDownloadSink {
  TempFileSink._(this._inner);

  final OffsetFileSink _inner;

  /// The temp file being written. The caller deletes this when done.
  File get file => _inner.file;

  static Future<TempFileSink> create(
    String fileName, {
    String subdir = 'mobissh_pdf',
  }) async {
    final base = await getTemporaryDirectory();
    final dir = await Directory(
      '${base.path}/$subdir',
    ).create(recursive: true);
    final safeName = _sanitizeTemp(fileName);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${dir.path}/$stamp-$safeName');
    final inner = await OffsetFileSink.create(file);
    return TempFileSink._(inner);
  }

  static String _sanitizeTemp(String name) {
    final base = name.split('/').last.split('\\').last;
    return base.isEmpty ? 'preview.pdf' : base;
  }

  @override
  Future<void> addChunk(Uint8List bytes, int offset) =>
      _inner.addChunk(bytes, offset);

  @override
  Future<String> finish({int? expectedTotal}) =>
      _inner.finish(expectedTotal: expectedTotal);

  @override
  Future<void> abort() => _inner.abort();
}
