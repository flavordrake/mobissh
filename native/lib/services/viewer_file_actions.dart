// Shared Download + Share pipeline for every in-app file viewer (#1038).
//
// Every preview state (text/code #776, markdown #854, HTML #1037, PDF #557,
// tap-to-fill media #946) offers the same two actions without navigating back
// to the browser:
//   - DOWNLOAD: stream the file to the device's Downloads through the SAME
//     sink pipeline the file browser uses (`downloadSinkFactoryProvider` →
//     [AppDownloadsSink] → MediaStore publish, #559/#952),
//   - SHARE: stage a LOCAL temp copy (the share sheet receives a FILE with a
//     correct mime type, never a path string) and hand it to share_plus.
//
// Two source shapes:
//   - [RemoteFileSource]: the viewed remote entry — streamed over the session
//     proxy's sftpDownload/sftpEvents, chunks written at their byte offset
//     (#591 semantics). The stream→sink loop mirrors pdf_fetcher.dart; the
//     proven PDF fetch path is deliberately left untouched rather than
//     refactored under it.
//   - [BytesFileSource]: content the viewer ALREADY holds in memory (an
//     inline markdown image's fetched bytes, a mermaid diagram's source) —
//     written straight through the sink, no second fetch.
//
// Injectable seams: the download sink factory (browser's provider), the share
// staging sink, and the share launcher ([viewerShareLauncherProvider]) — so
// widget tests spy the service, unit tests capture sinks, and the emulator
// test intercepts the final platform call.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'html_loopback_server.dart' show contentTypeForName;
import 'session_messages.dart';
import 'sftp_download.dart';

/// A file a viewer can download/share. Sealed: viewers either reference the
/// remote entry they are previewing or the bytes they already fetched.
sealed class ViewerFileSource {
  const ViewerFileSource();

  /// Display/destination file name (basename).
  String get fileName;
}

/// The remote SFTP entry a viewer is previewing on [sessionId].
class RemoteFileSource extends ViewerFileSource {
  const RemoteFileSource({required this.sessionId, required this.entry});

  final String sessionId;
  final SftpEntry entry;

  @override
  String get fileName => entry.name;
}

/// In-memory content a viewer already holds (inline image bytes, mermaid
/// source). Written through the sink directly — no re-fetch.
class BytesFileSource extends ViewerFileSource {
  const BytesFileSource({required this.fileName, required this.bytes});

  @override
  final String fileName;
  final Uint8List bytes;
}

/// Plain (parameter-free) mime type for sharing [name] by extension. Delegates
/// to the loopback server's content-type table (single source of truth) with
/// the `; charset=…` parameter stripped — Android share intents want a bare
/// type. `.mmd` (mermaid source) shares as text; unknown → octet-stream.
String viewerShareMimeType(String name) {
  final dot = name.lastIndexOf('.');
  final ext = (dot <= 0 || dot == name.length - 1)
      ? ''
      : name.substring(dot + 1).toLowerCase();
  if (ext == 'mmd') return 'text/plain';
  final full = contentTypeForName(name);
  final semi = full.indexOf(';');
  return semi == -1 ? full : full.substring(0, semi).trim();
}

/// Launches the platform share sheet with a staged local file. Injected via
/// [viewerShareLauncherProvider] so tests never open the real sheet.
typedef ViewerShareLauncher =
    Future<void> Function(String path, String mimeType, String fileName);

/// Production launcher: share_plus with the FILE + mime (same idiom as the
/// diagnostics crash-report share).
Future<void> defaultViewerShareLauncher(
  String path,
  String mimeType,
  String fileName,
) async {
  await Share.shareXFiles([XFile(path, mimeType: mimeType, name: fileName)]);
}

/// The active share launcher. The emulator test overrides this final hop to
/// assert the staged file + mime without automating system UI.
final viewerShareLauncherProvider = Provider<ViewerShareLauncher>(
  (ref) => defaultViewerShareLauncher,
);

/// Resolves the staging sink for a share (a private temp file the share sheet
/// reads). Separate from the DOWNLOAD sink factory: shares must never land in
/// the user-visible Downloads.
typedef ShareStageFactory = Future<FileDownloadSink> Function(String fileName);

Future<FileDownloadSink> _defaultShareStageFactory(String fileName) =>
    TempFileSink.create(fileName, subdir: 'mobissh_share');

/// Download + Share entry points for the viewer actions widget. Widget tests
/// substitute a spy via [fileViewerActionServiceProvider].
abstract class FileViewerActionService {
  /// Saves [source] to the device Downloads (browser pipeline). Returns the
  /// human-readable location for the success toast.
  Future<String> downloadToDevice(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  });

  /// Stages [source] as a local temp file and opens the share sheet with it
  /// (correct mime type — the FILE is shared, not its path).
  Future<void> shareFile(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  });
}

/// Production service. All seams injectable for tests.
class ProxyFileViewerActionService implements FileViewerActionService {
  ProxyFileViewerActionService(
    this._ref, {
    this.downloadSinkFactory,
    ShareStageFactory? shareStageFactory,
    this.shareLauncher,
  }) : _shareStageFactory = shareStageFactory ?? _defaultShareStageFactory;

  final Ref _ref;

  /// Test seam: overrides the provider-resolved download sink factory.
  final DownloadSinkFactory? downloadSinkFactory;
  final ShareStageFactory _shareStageFactory;

  /// Test seam: overrides the provider-resolved share launcher.
  final ViewerShareLauncher? shareLauncher;
  int _seq = 0;

  @override
  Future<String> downloadToDevice(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  }) async {
    // Default at CALL time so a test's provider override applies (the browser
    // and the viewer actions honor the same override — emulator tests rely
    // on this).
    final DownloadSinkFactory sinkFactory =
        downloadSinkFactory ?? _ref.read(downloadSinkFactoryProvider);
    final sink = await sinkFactory(source.fileName);
    return _fill(source, sink, onProgress);
  }

  @override
  Future<void> shareFile(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final sink = await _shareStageFactory(source.fileName);
    final path = await _fill(source, sink, onProgress);
    final ViewerShareLauncher launcher =
        shareLauncher ?? _ref.read(viewerShareLauncherProvider);
    // The staged temp copy is deliberately KEPT after the launcher returns:
    // the receiving app may still be reading the content URI. Files live in
    // the app's temp dir under mobissh_share/ where the OS may reclaim them.
    await launcher(path, viewerShareMimeType(source.fileName), source.fileName);
  }

  /// Writes [source] through [sink]; returns [FileDownloadSink.finish]'s
  /// location. Aborts the sink on any failure so partial files are cleaned.
  Future<String> _fill(
    ViewerFileSource source,
    FileDownloadSink sink,
    void Function(int received, int? total)? onProgress,
  ) async {
    switch (source) {
      case BytesFileSource():
        try {
          await sink.addChunk(source.bytes, 0);
          onProgress?.call(source.bytes.length, source.bytes.length);
          return await sink.finish(expectedTotal: source.bytes.length);
        } catch (e) {
          await sink.abort();
          rethrow;
        }
      case RemoteFileSource():
        return _fetchRemote(source, sink, onProgress);
    }
  }

  /// Streams the remote entry into [sink] via the session proxy — the same
  /// sftpDownload/sftpEvents flow as the browser and pdf_fetcher. Chunk writes
  /// are chained so `done` runs after every write and write errors surface;
  /// each chunk lands at its byte offset (#591: arrival order is not offset
  /// order).
  Future<String> _fetchRemote(
    RemoteFileSource source,
    FileDownloadSink sink,
    void Function(int received, int? total)? onProgress,
  ) async {
    final proxy = _resolveProxy(source.sessionId);
    if (proxy == null) {
      await sink.abort();
      throw StateError('Session is no longer available');
    }

    final requestId = '${source.sessionId}#vact${_seq++}';
    final completer = Completer<String>();
    var received = 0;
    Future<void> pending = Future<void>.value();

    late final StreamSubscription<SshTaskEvent> sub;
    Future<void> cleanupAndFail(Object error) async {
      await sink.abort();
      if (!completer.isCompleted) completer.completeError(error);
    }

    sub = proxy.sftpEvents.listen((event) {
      switch (event) {
        case SftpDownloadChunkEvent():
          if (event.requestId != requestId) return;
          received += event.bytes.length;
          onProgress?.call(received, event.totalBytes);
          final bytes = event.bytes;
          final offset = event.offset;
          pending = pending.then((_) => sink.addChunk(bytes, offset));
        case SftpDownloadDoneEvent():
          if (event.requestId != requestId) return;
          final expected = event.totalBytes;
          unawaited(() async {
            try {
              await pending; // drain all chunk writes first
              final location = await sink.finish(expectedTotal: expected);
              if (!completer.isCompleted) completer.complete(location);
            } catch (e) {
              await cleanupAndFail(e);
            }
          }());
        case SftpErrorEvent():
          if (event.requestId != requestId) return;
          unawaited(cleanupAndFail(Exception(event.message)));
        default:
          break;
      }
    });

    proxy.sftpDownload(requestId: requestId, path: source.entry.path);

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  SshSessionProxy? _resolveProxy(String sessionId) {
    final entries = _ref.read(sessionsProvider).entries;
    for (final e in entries) {
      if (e.id == sessionId) return e.proxy;
    }
    return null;
  }
}

/// The active service. Widget tests override with a spy.
final fileViewerActionServiceProvider = Provider<FileViewerActionService>(
  (ref) => ProxyFileViewerActionService(ref),
);
