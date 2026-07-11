// HTML loopback resolver (#1037, epic #944).
//
// A per-viewer dart:io [HttpServer] that lets the WebView-rendered HTML
// viewer resolve RELATIVE references (linked CSS, images, scripts) against
// the opened file's REMOTE directory: the WebView loads
// `http://127.0.0.1:<port>/<file>.html`, and every request the page makes is
// mapped to an SFTP read rooted at that directory. Relative refs — including
// nested dirs — then "just work" without rewriting the document.
//
// SECURITY POSTURE (rules/security.md):
//   - binds 127.0.0.1 ONLY, on an EPHEMERAL (random) port — unreachable off
//     device; no other app origin is granted anything it could not already
//     get by running on the same device as a debuggable local socket, and the
//     served tree is limited (below);
//   - serves ONLY the directory tree rooted at the opened HTML file's remote
//     directory. Every request path is normalized ([resolveLoopbackAssetPath])
//     and verified to stay UNDER that root — `..` escapes (including
//     percent-encoded dot segments, which are decoded before resolution)
//     answer 404 and never reach SFTP;
//   - content is fetched on demand over the user's OWN authenticated SFTP
//     session (files they can already read), never cached to disk;
//   - session-scoped lifetime: started when the viewer route opens, closed on
//     its dispose. Nothing outlives the viewer.
//
// Reads are capped per asset ([maxAssetBytes], default 8 MiB — matching the
// SftpImageFetcher cap) so one huge referenced asset can't exhaust memory;
// past the cap the server answers 413. The byte source is injected
// ([LoopbackByteFetcher]) so unit tests exercise the full HTTP surface with a
// fake fetcher and production wires the SFTP image fetcher (raw bytes, no
// binary-reject).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Fetches the raw bytes of [remotePath] (an absolute POSIX path on the SFTP
/// host). Throws on miss — the server answers 404.
typedef LoopbackByteFetcher = Future<Uint8List> Function(String remotePath);

/// Per-asset size cap (8 MiB — the SftpImageFetcher default). One page asset
/// larger than this answers 413 instead of ballooning memory.
const int kLoopbackAssetCap = 8 * 1024 * 1024;

/// Resolves a decoded request path (e.g. `/css/style.css`) against the served
/// [rootDir] (absolute POSIX directory). Returns the absolute remote path to
/// fetch, or `null` when the request escapes the root (path traversal), names
/// the root itself, or is empty — all of which the server answers with 404.
///
/// `.`/`..`/empty segments are collapsed BEFORE the containment check, so a
/// path that dips out and back in (`/sub/../x.css`) is fine while a genuine
/// escape (`/../secrets`) — or a sibling-prefix escape (`/../site-secrets/…`)
/// — is rejected.
String? resolveLoopbackAssetPath(String rootDir, String requestPath) {
  final root = _normalizeAbsolutePosix(
    rootDir.startsWith('/') ? rootDir : '/$rootDir',
  );
  var rel = requestPath;
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  if (rel.isEmpty) return null;
  final base = root == '/' ? '' : root;
  final resolved = _normalizeAbsolutePosix('$base/$rel');
  if (resolved == root) return null; // the root itself is a directory
  final prefix = root == '/' ? '/' : '$root/';
  if (!resolved.startsWith(prefix)) return null; // traversal escape
  return resolved;
}

/// Collapses `.` / `..` / empty segments in an absolute POSIX path. `..` is
/// clamped at the root (an absolute path cannot escape `/`).
String _normalizeAbsolutePosix(String p) {
  final out = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return '/${out.join('/')}';
}

/// Directory part of an absolute POSIX [path] (`/a/b/c.html` → `/a/b`).
String dirnamePosix(String path) {
  final i = path.lastIndexOf('/');
  if (i <= 0) return '/';
  return path.substring(0, i);
}

/// Content types for the common web asset extensions; anything unknown is
/// `application/octet-stream`. Text types carry `charset=utf-8`.
const Map<String, String> _contentTypes = {
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
  'md': 'text/markdown; charset=utf-8',
  'xml': 'application/xml; charset=utf-8',
  'svg': 'image/svg+xml; charset=utf-8',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'ico': 'image/x-icon',
  'avif': 'image/avif',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'wasm': 'application/wasm',
  'pdf': 'application/pdf',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mp3': 'audio/mpeg',
};

/// Maps a file [name] to its response content-type by extension
/// (case-insensitive); unknown/missing extensions default to octet-stream.
String contentTypeForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return 'application/octet-stream';
  final ext = name.substring(dot + 1).toLowerCase();
  return _contentTypes[ext] ?? 'application/octet-stream';
}

/// The loopback micro-server. One instance per open HTML viewer:
/// [start] on route mount, [close] on dispose.
class HtmlLoopbackServer {
  HtmlLoopbackServer({
    required this.rootDir,
    required this.fetch,
    this.maxAssetBytes = kLoopbackAssetCap,
  });

  /// Absolute remote directory the served tree is rooted at (the opened HTML
  /// file's directory).
  final String rootDir;

  /// Byte source (production: the session's SFTP image fetcher).
  final LoopbackByteFetcher fetch;

  /// Per-asset response cap; larger fetches answer 413.
  final int maxAssetBytes;

  HttpServer? _server;

  /// Total requests answered (any status). Lets tests assert the WebView
  /// actually reached the loopback origin — e.g. catching a cleartext-blocked
  /// WebView config, which otherwise renders a blank/error page while every
  /// out-of-process probe still succeeds (#1037 emulator run caught exactly
  /// this: Android blocks cleartext HTTP by default, see
  /// android/app/src/main/res/xml/network_security_config.xml).
  int requestCount = 0;

  /// The bound ephemeral port, or null before [start] / after [close].
  int? get port => _server?.port;

  /// Loopback URI for a file directly under [rootDir] (the opened page).
  Uri uriFor(String fileName) {
    final p = port;
    if (p == null) {
      throw StateError('HtmlLoopbackServer is not running');
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: p,
      pathSegments: [fileName],
    );
  }

  /// Binds 127.0.0.1 on an ephemeral port and starts answering requests.
  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, cancelOnError: false);
  }

  /// Stops the server and closes the port (in-flight requests are aborted —
  /// the viewer is going away).
  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _respondStatus(request, HttpStatus.methodNotAllowed);
        return;
      }
      // pathSegments are percent-DECODED per segment, so encoded dot segments
      // (%2e%2e) are visible to the traversal guard below.
      final decodedPath = '/${request.uri.pathSegments.join('/')}';
      final remote = resolveLoopbackAssetPath(rootDir, decodedPath);
      if (remote == null) {
        await _respondStatus(request, HttpStatus.notFound);
        return;
      }
      Uint8List bytes;
      try {
        bytes = await fetch(remote);
      } catch (_) {
        // Miss / SFTP error → 404; the page keeps rendering without the asset.
        await _respondStatus(request, HttpStatus.notFound);
        return;
      }
      if (bytes.length > maxAssetBytes) {
        await _respondStatus(request, HttpStatus.requestEntityTooLarge);
        return;
      }
      final response = request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.contentTypeHeader, contentTypeForName(remote))
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentLength = bytes.length;
      if (request.method == 'GET') {
        response.add(bytes);
      }
      await response.close();
    } catch (_) {
      // Never let one bad request take the server down; best-effort close.
      try {
        await request.response.close();
      } catch (_) {
        // socket already gone
      }
    }
  }

  Future<void> _respondStatus(HttpRequest request, int status) async {
    request.response
      ..statusCode = status
      ..contentLength = 0;
    await request.response.close();
  }
}
