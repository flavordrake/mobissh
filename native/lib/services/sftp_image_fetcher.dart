// Image byte-fetch seam for the in-app markdown viewer (#946).
//
// The markdown viewer's `imageBuilder` resolves an inline `![](src)` reference
// to a remote path and streams its BYTES into memory using the SAME machinery
// the text/code viewer uses (the session proxy's `sftpDownload` command + the
// `sftpEvents` stream — chunks/done/error), assembling chunks at their byte
// offsets (#591). Unlike [TextFileFetcher] this does NOT UTF-8 decode and does
// NOT binary-reject — images ARE binary — it returns the raw [Uint8List].
//
// Exposed as a [SftpImageFetcher] interface + a [sftpImageFetcherProvider] so
// widget tests can substitute a fetcher that returns canned bytes without
// touching the SSH stack. [resolveSftpImagePath] is a pure path resolver
// (relative → the .md's directory; absolute → as-is; http(s)/data → null, i.e.
// not an SFTP path) so it can be unit-tested in isolation.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'session_messages.dart';

/// Resolves a markdown image [src] against the directory of the `.md` file at
/// [mdPath]. Returns the absolute remote SFTP path to fetch, or `null` when
/// [src] is NOT an SFTP target (an `http(s)://` / protocol-relative `//` /
/// `data:` URI — those are handled by the network/placeholder path, matching the
/// existing offline-first policy).
///
/// Relative paths (`img/a.png`, `../b.png`, `./c.png`) resolve against the .md's
/// directory; absolute paths (`/srv/x.png`) pass through normalized. `..`/`.`
/// segments are collapsed so the result is a clean absolute POSIX path.
String? resolveSftpImagePath(String mdPath, String src) {
  final s = src.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('//') ||
      lower.startsWith('data:')) {
    return null;
  }
  var rel = s;
  if (lower.startsWith('file://')) {
    rel = s.substring('file://'.length);
  }
  if (rel.startsWith('/')) {
    return _normalizePosix(rel);
  }
  final dir = _dirnamePosix(mdPath);
  final base = dir == '/' ? '' : dir;
  return _normalizePosix('$base/$rel');
}

String _dirnamePosix(String p) {
  final i = p.lastIndexOf('/');
  if (i < 0) return '/';
  if (i == 0) return '/';
  return p.substring(0, i);
}

String _normalizePosix(String p) {
  final isAbsolute = p.startsWith('/');
  final out = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!isAbsolute) {
        out.add('..');
      }
      // an absolute path can't escape root — drop leading '..'
      continue;
    }
    out.add(seg);
  }
  final joined = out.join('/');
  if (isAbsolute) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

/// Fetches the raw bytes of a remote image at [path] on [sessionId]. [maxBytes]
/// caps the in-memory buffer so an oversized image can't exhaust memory (it
/// throws past the cap, which the viewer renders as a placeholder).
abstract class SftpImageFetcher {
  Future<Uint8List> fetch(
    String sessionId,
    String path, {
    int maxBytes = 8 * 1024 * 1024,
  });
}

/// Production fetcher: resolves the session's [SshSessionProxy] and streams the
/// file over SFTP into an offset-indexed buffer (no decode, no binary reject).
class ProxySftpImageFetcher implements SftpImageFetcher {
  ProxySftpImageFetcher(this._ref);

  final Ref _ref;
  int _seq = 0;

  @override
  Future<Uint8List> fetch(
    String sessionId,
    String path, {
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final proxy = _resolveProxy(sessionId);
    if (proxy == null) {
      throw StateError('Session is no longer available');
    }

    final requestId = '$sessionId#img${_seq++}';
    final byOffset = <int, Uint8List>{};
    var received = 0;
    final completer = Completer<Uint8List>();

    late final StreamSubscription<SshTaskEvent> sub;
    sub = proxy.sftpEvents.listen((event) {
      switch (event) {
        case SftpDownloadChunkEvent():
          if (event.requestId != requestId) return;
          received += event.bytes.length;
          byOffset[event.offset] = event.bytes;
          if (received > maxBytes && !completer.isCompleted) {
            completer.completeError(
              StateError('Image is too large to preview'),
            );
          }
        case SftpDownloadDoneEvent():
          if (event.requestId != requestId) return;
          if (completer.isCompleted) return;
          final builder = BytesBuilder(copy: false);
          for (final offset in (byOffset.keys.toList()..sort())) {
            builder.add(byOffset[offset]!);
          }
          completer.complete(builder.takeBytes());
        case SftpErrorEvent():
          if (event.requestId != requestId) return;
          if (!completer.isCompleted) {
            completer.completeError(Exception(event.message));
          }
        default:
          break;
      }
    });

    proxy.sftpDownload(requestId: requestId, path: path);

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  SshSessionProxy? _resolveProxy(String sessionId) {
    for (final e in _ref.read(sessionsProvider).entries) {
      if (e.id == sessionId) return e.proxy;
    }
    return null;
  }
}

/// The active [SftpImageFetcher]. Production resolves a [ProxySftpImageFetcher];
/// widget tests override this with a fetcher that returns canned bytes.
final sftpImageFetcherProvider = Provider<SftpImageFetcher>(
  (ref) => ProxySftpImageFetcher(ref),
);
