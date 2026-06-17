// Text write seam (#892).
//
// Writes a String back to a remote text/code file using the SAME machinery the
// file browser/viewer uses for reads, in reverse: the session proxy's
// `sftpUpload` command + the `sftpEvents` stream (done/error). The String is
// UTF-8 encoded and uploaded WHOLE-FILE (write|create|truncate); nothing is
// staged to disk. This is the foundation every in-app file editor (#859
// markdown, SSH config, code) saves through.
//
// Exposed as a [TextFileWriter] interface + a [textFileWriterProvider] so widget
// tests can substitute a writer that records bytes without touching the SSH
// stack — the mirror of [TextFileFetcher] / [textFileFetcherProvider].

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'session_messages.dart';

/// Writes [content] (UTF-8 encoded) to the remote file at [path] over the
/// session identified by [sessionId]. Completes with the number of bytes
/// written on success; throws on an SFTP error. Whole-file replace.
abstract class TextFileWriter {
  Future<int> write(String sessionId, String path, String content);
}

/// Production writer: resolves the session's [SshSessionProxy] and uploads the
/// UTF-8 bytes over SFTP, completing when the matching [SftpUploadDoneEvent]
/// arrives (or erroring on a matching [SftpErrorEvent]). The mirror of
/// [ProxyTextFileFetcher].
class ProxyTextFileWriter implements TextFileWriter {
  ProxyTextFileWriter(this._ref);

  final Ref _ref;
  int _seq = 0;

  @override
  Future<int> write(String sessionId, String path, String content) async {
    final proxy = _resolveProxy(sessionId);
    if (proxy == null) {
      throw StateError('Session is no longer available');
    }

    final requestId = '$sessionId#write${_seq++}';
    final bytes = Uint8List.fromList(utf8.encode(content));
    final completer = Completer<int>();

    late final StreamSubscription<SshTaskEvent> sub;

    sub = proxy.sftpEvents.listen((event) {
      switch (event) {
        case SftpUploadDoneEvent():
          if (event.requestId != requestId) return;
          if (completer.isCompleted) return;
          completer.complete(event.totalBytes);
        case SftpErrorEvent():
          if (event.requestId != requestId) return;
          if (!completer.isCompleted) {
            completer.completeError(Exception(event.message));
          }
        default:
          break;
      }
    });

    proxy.sftpUpload(requestId: requestId, path: path, bytes: bytes);

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

/// The active [TextFileWriter]. Production resolves a [ProxyTextFileWriter];
/// widget tests override this with a writer that records bytes.
final textFileWriterProvider = Provider<TextFileWriter>(
  (ref) => ProxyTextFileWriter(ref),
);
