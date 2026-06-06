// Text fetch seam (#776).
//
// Streams a remote text/code file into memory using the SAME machinery the file
// browser uses for downloads: the session proxy's `sftpDownload` command + the
// `sftpEvents` stream (chunks/done/error). Chunks are assembled at their byte
// offsets (#591) and the result is decoded as UTF-8 (lossy — malformed bytes
// become the replacement char rather than throwing). The text viewer renders
// the decoded String; nothing is written to disk.
//
// Exposed as a [TextFileFetcher] interface + a [textFileFetcherProvider] so
// widget tests can substitute a fetcher that returns canned text without
// touching the SSH stack.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'session_messages.dart';

/// Fetches the text content of [entry] (a remote text/code file) and returns it
/// decoded as a String. [maxBytes] caps the in-memory buffer so a huge file
/// can't exhaust memory. [onProgress] reports received / total bytes.
abstract class TextFileFetcher {
  Future<String> fetch(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  });
}

/// Production fetcher: resolves the session's [SshSessionProxy] and streams the
/// file over SFTP into an in-memory, offset-indexed buffer, then UTF-8 decodes.
class ProxyTextFileFetcher implements TextFileFetcher {
  ProxyTextFileFetcher(this._ref);

  final Ref _ref;
  int _seq = 0;

  @override
  Future<String> fetch(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async {
    final proxy = _resolveProxy(sessionId);
    if (proxy == null) {
      throw StateError('Session is no longer available');
    }

    final requestId = '$sessionId#text${_seq++}';
    final buffer = BytesBuilder(copy: false);
    // Chunks can arrive reordered over the gateway (#591); index by offset so
    // the decoded bytes are correct regardless of arrival order.
    final byOffset = <int, Uint8List>{};
    var received = 0;
    final completer = Completer<String>();

    late final StreamSubscription<SshTaskEvent> sub;

    sub = proxy.sftpEvents.listen((event) {
      switch (event) {
        case SftpDownloadChunkEvent():
          if (event.requestId != requestId) return;
          received += event.bytes.length;
          onProgress?.call(received, event.totalBytes);
          byOffset[event.offset] = event.bytes;
          if (received > maxBytes && !completer.isCompleted) {
            completer.completeError(
              StateError('File is too large to preview'),
            );
          }
        case SftpDownloadDoneEvent():
          if (event.requestId != requestId) return;
          if (completer.isCompleted) return;
          for (final offset in (byOffset.keys.toList()..sort())) {
            buffer.add(byOffset[offset]!);
          }
          completer.complete(utf8.decode(buffer.takeBytes(), allowMalformed: true));
        case SftpErrorEvent():
          if (event.requestId != requestId) return;
          if (!completer.isCompleted) {
            completer.completeError(Exception(event.message));
          }
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

/// The active [TextFileFetcher]. Production resolves a [ProxyTextFileFetcher];
/// widget tests override this with a fetcher that returns canned text.
final textFileFetcherProvider = Provider<TextFileFetcher>(
  (ref) => ProxyTextFileFetcher(ref),
);
