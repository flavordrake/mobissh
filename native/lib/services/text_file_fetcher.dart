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

/// User-facing message surfaced when the fetched content looks binary. The
/// viewer's existing error path renders this so the user is told to download
/// rather than shown mojibake (#893).
const String binaryFileMessage = 'Binary file — download instead';

/// Thrown by the fetcher when [isBinaryContent] flags the downloaded bytes as
/// binary. Carries the user-facing [binaryFileMessage].
class BinaryFileException implements Exception {
  const BinaryFileException();

  @override
  String toString() => binaryFileMessage;
}

/// True when [bytes] look like binary (not human-readable text). Examines only
/// the leading [sampleBytes] (first ~64 KB) so it stays cheap on large files:
///   - any NUL byte (`0x00`) in the sample → binary (NUL never appears in text);
///   - otherwise, if more than [threshold] (default ~30%) of the sampled bytes
///     are non-printable, treat as binary.
/// Printable = tab/newline/carriage-return, or any byte >= 0x20 that is not the
/// DEL control (0x7F). Bytes >= 0x80 are allowed as potential UTF-8 multibyte
/// continuation/lead bytes, so valid UTF-8 text is not misclassified. An empty
/// buffer is text.
bool isBinaryContent(
  Uint8List bytes, {
  int sampleBytes = 64 * 1024,
  double threshold = 0.30,
}) {
  if (bytes.isEmpty) return false;
  final limit = bytes.length < sampleBytes ? bytes.length : sampleBytes;
  var nonPrintable = 0;
  for (var i = 0; i < limit; i++) {
    final b = bytes[i];
    if (b == 0x00) return true; // NUL — definitive binary marker.
    final isPrintable =
        b == 0x09 || // tab
        b == 0x0A || // LF
        b == 0x0D || // CR
        (b >= 0x20 && b != 0x7F) || // printable ASCII (excl. DEL)
        b >= 0x80; // possible UTF-8 multibyte byte
    if (!isPrintable) nonPrintable++;
  }
  return nonPrintable > limit * threshold;
}

/// Fetches the text content of [entry] (a remote text/code file) and returns it
/// decoded as a String. [maxBytes] caps the in-memory buffer so a huge file
/// can't exhaust memory. [onProgress] reports received / total bytes. Throws a
/// [BinaryFileException] if the content looks binary.
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
          final assembled = buffer.takeBytes();
          if (isBinaryContent(assembled)) {
            completer.completeError(const BinaryFileException());
            return;
          }
          completer.complete(utf8.decode(assembled, allowMalformed: true));
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
