// Image detection (#1093, slice of #635).
//
// Pure helpers deciding whether a tapped SFTP entry should route to the in-app
// image viewer. Detection is by filename extension (case-insensitive) and/or an
// explicit `image/*` MIME type. Kept dependency-free so it's trivially
// unit-testable and shared between the viewer registry and any future routing.
//
// SVG is deliberately EXCLUDED: it's also matched by the text viewer and is
// legitimately viewed as source. Everything here is a raster/web-renderable
// image the WebView shows as a picture (animated GIF/APNG animate natively).

import 'session_messages.dart';

/// Web-renderable raster image extensions. Lowercase, no leading dot. Maps to a
/// MIME in [imageMimeForName] so the viewer can build a correct `data:` URI.
const Set<String> _imageExtensions = {
  'png',
  'apng',
  'jpg',
  'jpeg',
  'jfif',
  'gif',
  'webp',
  'bmp',
  'avif',
  'ico',
};

/// Extension → `data:` URI media type. Kept alongside [_imageExtensions] so the
/// two never drift. Unknown/invalid extensions return null (not an image).
const Map<String, String> _extMime = {
  'png': 'image/png',
  'apng': 'image/apng',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'jfif': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'avif': 'image/avif',
  'ico': 'image/x-icon',
};

/// The lowercase extension of [name] without the leading dot, or null when
/// [name] has no real extension (a bare `png`, a trailing dot, or a dotfile).
String? _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// True when [name] ends with a known image extension (case-insensitive).
/// Requires a real extension — a bare `png` or `noext` does not match.
bool hasImageExtension(String name) {
  final ext = _extensionOf(name);
  return ext != null && _imageExtensions.contains(ext);
}

/// True when [mime] denotes a raster image (`image/*`), EXCEPT `image/svg+xml`
/// (SVG routes to the text viewer). MIME parameters (`; charset=…`) are ignored.
/// Null / empty / non-image types are false.
bool isImageMime(String? mime) {
  if (mime == null || mime.isEmpty) return false;
  final base = mime.split(';').first.trim().toLowerCase();
  if (base == 'image/svg+xml') return false;
  return base.startsWith('image/');
}

/// True when [entry] is a regular file that looks like a raster image, by
/// extension or by an explicit [mime]. Directories are never images.
bool isImageEntry(SftpEntry entry, {String? mime}) {
  if (entry.isDirectory) return false;
  return hasImageExtension(entry.name) || isImageMime(mime);
}

/// The `data:` URI media type for [name]'s extension (e.g. `image/png`), or a
/// safe default of `image/png` when the extension is unknown — the viewer only
/// opens entries that already passed [isImageEntry], so a miss here is a
/// belt-and-braces fallback rather than a real code path.
String imageMimeForName(String name) {
  final ext = _extensionOf(name);
  return (ext == null ? null : _extMime[ext]) ?? 'image/png';
}
