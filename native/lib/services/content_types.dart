// Content-type-by-extension table (#1107).
//
// Rehomed from the deleted html_loopback_server.dart (Approach A removed the
// loopback micro-server). This is a pure, dependency-free lookup shared by the
// viewer Download/Share actions ([viewerShareMimeType]) and the HTML inliner
// (data: URI media types for inlined assets).

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
