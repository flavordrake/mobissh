// SFTP download destination seam (#559, #591).
//
// The task isolate streams file chunks across IPC (base64); the UI assembles
// them into a destination on the device. This file owns the *destination*
// abstraction so the chunk-assembly logic is reusable and the storage backend
// is swappable:
//
//   - MVP / this slice: [AppDownloadsSink] writes into the app's external
//     "Downloads" directory via path_provider — no MANAGE_EXTERNAL_STORAGE,
//     no SAF prompt. Good enough to validate the round-trip end-to-end.
//   - Follow-up (owner-validated on device): a SAF/MediaStore-backed sink that
//     drops files into the shared Downloads collection the user sees in their
//     file manager. Slot it in by implementing [FileDownloadSink].
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

import 'package:path_provider/path_provider.dart';

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

/// Writes into the app's external Downloads directory (Android) or the app
/// documents directory (fallback). Scoped storage — no broad-storage perms.
/// Delegates offset-honoring assembly + length verification to [OffsetFileSink].
class AppDownloadsSink implements FileDownloadSink {
  AppDownloadsSink._(this._inner);

  final OffsetFileSink _inner;

  /// The destination file path (for tests / callers that need it).
  String get path => _inner.file.path;

  static Future<AppDownloadsSink> create(String fileName) async {
    final dir = await _resolveDownloadsDir();
    final safeName = _sanitize(fileName);
    final file = File('${dir.path}/$safeName');
    final inner = await OffsetFileSink.create(file);
    return AppDownloadsSink._(inner);
  }

  static Future<Directory> _resolveDownloadsDir() async {
    // getDownloadsDirectory() is null on Android; fall back to the app's
    // external storage dir's Download subfolder, then app documents.
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {
      dir = null;
    }
    if (dir == null) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          dir = Directory('${ext.path}/Download');
        }
      } catch (_) {
        dir = null;
      }
    }
    dir ??= await getApplicationDocumentsDirectory();
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
  Future<String> finish({int? expectedTotal}) =>
      _inner.finish(expectedTotal: expectedTotal);

  @override
  Future<void> abort() => _inner.abort();
}

/// Writes a download into a private app TEMP directory rather than Downloads.
/// Used by the in-app PDF viewer (#557): the file is fetched to temp, rendered,
/// then deleted on close. [finish] returns the temp file path; [file] exposes
/// the [File] so the caller can delete it explicitly. Delegates offset-honoring
/// assembly + length verification to [OffsetFileSink].
class TempFileSink implements FileDownloadSink {
  TempFileSink._(this._inner);

  final OffsetFileSink _inner;

  /// The temp file being written. The caller deletes this when done.
  File get file => _inner.file;

  static Future<TempFileSink> create(String fileName) async {
    final base = await getTemporaryDirectory();
    final dir = await Directory(
      '${base.path}/mobissh_pdf',
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
