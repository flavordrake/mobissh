// SFTP download destination seam (#559).
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

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// A growing destination for a single downloaded file. Chunks arrive in order
/// from the task isolate; [addChunk] appends, [finish] flushes + returns a
/// human-readable location for the success snackbar.
abstract class FileDownloadSink {
  Future<void> addChunk(Uint8List bytes);

  /// Flush + close. Returns a display path / URI for the completion message.
  Future<String> finish();

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

/// Writes into the app's external Downloads directory (Android) or the app
/// documents directory (fallback). Scoped storage — no broad-storage perms.
class AppDownloadsSink implements FileDownloadSink {
  AppDownloadsSink._(this._file, this._sink);

  final File _file;
  final IOSink _sink;

  static Future<AppDownloadsSink> create(String fileName) async {
    final dir = await _resolveDownloadsDir();
    final safeName = _sanitize(fileName);
    final file = File('${dir.path}/$safeName');
    final sink = file.openWrite();
    return AppDownloadsSink._(file, sink);
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
  Future<void> addChunk(Uint8List bytes) async {
    _sink.add(bytes);
  }

  @override
  Future<String> finish() async {
    await _sink.flush();
    await _sink.close();
    return _file.path;
  }

  @override
  Future<void> abort() async {
    try {
      await _sink.close();
    } catch (_) {
      /* ignore */
    }
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {
      /* ignore */
    }
  }
}

/// Writes a download into a private app TEMP directory rather than Downloads.
/// Used by the in-app PDF viewer (#557): the file is fetched to temp, rendered,
/// then deleted on close. [finish] returns the temp file path; [file] exposes
/// the [File] so the caller can delete it explicitly.
class TempFileSink implements FileDownloadSink {
  TempFileSink._(this.file, this._sink);

  /// The temp file being written. The caller deletes this when done.
  final File file;
  final IOSink _sink;

  static Future<TempFileSink> create(String fileName) async {
    final base = await getTemporaryDirectory();
    final dir = await Directory(
      '${base.path}/mobissh_pdf',
    ).create(recursive: true);
    final safeName = _sanitizeTemp(fileName);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${dir.path}/$stamp-$safeName');
    return TempFileSink._(file, file.openWrite());
  }

  static String _sanitizeTemp(String name) {
    final base = name.split('/').last.split('\\').last;
    return base.isEmpty ? 'preview.pdf' : base;
  }

  @override
  Future<void> addChunk(Uint8List bytes) async {
    _sink.add(bytes);
  }

  @override
  Future<String> finish() async {
    await _sink.flush();
    await _sink.close();
    return file.path;
  }

  @override
  Future<void> abort() async {
    try {
      await _sink.close();
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
