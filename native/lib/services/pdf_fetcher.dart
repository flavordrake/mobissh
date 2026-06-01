// PDF fetch seam (#557).
//
// Streams a remote `.pdf` to a private temp file using the SAME machinery the
// file browser uses for downloads: the session proxy's `sftpDownload` command
// + the `sftpEvents` stream (chunks/done/error), assembled into a
// [TempFileSink]. The PDF viewer then renders the temp file and deletes it on
// close.
//
// Exposed as a [PdfFetcher] interface + a [pdfFetcherProvider] so widget tests
// can substitute a fetcher that writes bundled bytes without touching the SSH
// stack or pdfium.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'session_messages.dart';
import 'sftp_download.dart';

/// Fetches the bytes for [entry] (a remote PDF) and returns a local [File].
/// [onProgress] reports received / total bytes for a progress indicator.
abstract class PdfFetcher {
  Future<File> fetch(
    String sessionId,
    SftpEntry entry, {
    void Function(int received, int? total)? onProgress,
  });
}

/// Production fetcher: resolves the session's [SshSessionProxy] from the
/// sessions collection and streams the file over SFTP into a [TempFileSink].
class ProxyPdfFetcher implements PdfFetcher {
  ProxyPdfFetcher(this._ref);

  final Ref _ref;
  int _seq = 0;

  @override
  Future<File> fetch(
    String sessionId,
    SftpEntry entry, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final proxy = _resolveProxy(sessionId);
    if (proxy == null) {
      throw StateError('Session is no longer available');
    }

    final requestId = '$sessionId#pdf${_seq++}';
    final sink = await TempFileSink.create(entry.name);
    final completer = Completer<File>();
    var received = 0;

    // Serialize sink writes through a single Future chain. Chunks can arrive
    // reordered over the gateway (#591); the sink writes each at its offset, so
    // ordering doesn't affect correctness, but we still chain so `done` runs
    // AFTER every chunk write has completed and so write errors surface.
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
              await sink.finish(expectedTotal: expected);
              if (!completer.isCompleted) completer.complete(sink.file);
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

    proxy.sftpDownload(requestId: requestId, path: entry.path);

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

/// The active [PdfFetcher]. Production resolves a [ProxyPdfFetcher]; widget
/// tests override this with a fetcher that writes bundled bytes.
final pdfFetcherProvider = Provider<PdfFetcher>((ref) => ProxyPdfFetcher(ref));
