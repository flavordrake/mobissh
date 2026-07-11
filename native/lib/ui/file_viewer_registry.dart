// File viewer registry (#776).
//
// Generalizes the single `.pdf` tap interceptor (#557) into a registry of
// in-app viewers keyed by content type. When a file is tapped in the SFTP
// browser, the registry is consulted: if some registered viewer matches the
// entry it opens that viewer (and the tap is handled); otherwise the browser
// falls through to its existing download behavior.
//
// Each [FileViewer] is a (matches, open) pair:
//   - `matches(entry, mime)` — does this viewer handle the entry? (by extension
//     / MIME, via the pure detect helpers).
//   - `open(context, sessionId, entry)` — push the viewer route.
//
// Registered by default: the PDF viewer (#557) and the text/code viewer (#776).
// Viewers are READ-ONLY in this slice. State is per-route (sessionId + entry) —
// no global viewer state, so multiple sessions don't share preview state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/pdf_detect.dart';
import '../services/session_messages.dart';
import '../services/text_file_detect.dart';
import 'file_browser_screen.dart';
import 'html_file_viewer.dart';
import 'markdown_file_viewer.dart';
import 'text_file_viewer.dart';

/// A single registered in-app viewer.
class FileViewer {
  const FileViewer({required this.matches, required this.open});

  /// True when this viewer handles [entry] (optionally informed by a server
  /// [mime] type). Directories never match.
  final bool Function(SftpEntry entry, {String? mime}) matches;

  /// Opens the viewer route for [entry] on [sessionId].
  final void Function(BuildContext context, String sessionId, SftpEntry entry)
  open;
}

/// Ordered list of registered viewers. First match wins.
class FileViewerRegistry {
  const FileViewerRegistry(this._viewers);

  final List<FileViewer> _viewers;

  /// The registered viewers, in match order. Exposed for the #1038 drift
  /// guard: every registered viewer must render the shared Download + Share
  /// actions, and the guard pins this list's size.
  List<FileViewer> get viewers => List.unmodifiable(_viewers);

  /// Returns the first viewer that matches [entry], or null if none do (the
  /// browser then falls back to download).
  FileViewer? viewerFor(SftpEntry entry, {String? mime}) {
    if (entry.isDirectory) return null;
    for (final v in _viewers) {
      if (v.matches(entry, mime: mime)) return v;
    }
    return null;
  }
}

/// The active viewer registry. Defaults to the PDF viewer (#557, routed through
/// the existing [pdfTapInterceptorProvider] so its null-override / spy seam is
/// preserved), the markdown viewer (#854), and the text/code viewer (#776).
/// Tests can override this to add, remove, or stub viewers.
///
/// ORDER MATTERS — first match wins. The markdown viewer is registered BEFORE
/// the generic text viewer so a `.md` / `.markdown` file (which `isTextEntry`
/// also matches) routes to the rendered markdown viewer, not the raw monospace
/// one.
final fileViewerRegistryProvider = Provider<FileViewerRegistry>((ref) {
  return FileViewerRegistry([
    // PDF (#557): delegate to the existing interceptor provider so callers that
    // override it to null (fall through to download) or to a spy keep working.
    FileViewer(
      matches: (entry, {mime}) =>
          ref.read(pdfTapInterceptorProvider) != null &&
          isPdfEntry(entry, mime: mime),
      open: (context, sessionId, entry) {
        ref.read(pdfTapInterceptorProvider)!(context, sessionId, entry);
      },
    ),
    // Markdown (#854): rendered HTML + raw toggle (PWA parity). MUST precede the
    // generic text viewer — `.md`/`.markdown` are also text, first match wins.
    FileViewer(
      matches: (entry, {mime}) => isMarkdownEntry(entry, mime: mime),
      open: (context, sessionId, entry) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kFileBrowserRouteName),
            builder: (_) =>
                MarkdownFileViewerScreen(sessionId: sessionId, entry: entry),
          ),
        );
      },
    ),
    // HTML (#1037): rendered in a WebView with SFTP-backed relative
    // resolution (loopback resolver). MUST precede the generic text viewer —
    // `.html`/`.htm` are also text, first match wins. "View source" in its
    // app bar escapes to the text viewer.
    FileViewer(
      matches: (entry, {mime}) => isHtmlEntry(entry, mime: mime),
      open: (context, sessionId, entry) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kFileBrowserRouteName),
            builder: (_) =>
                HtmlFileViewerScreen(sessionId: sessionId, entry: entry),
          ),
        );
      },
    ),
    // Text / code (#776): read-only monospace preview (the fallback for all
    // other previewable text/code formats).
    FileViewer(
      matches: (entry, {mime}) => isTextEntry(entry, mime: mime),
      open: (context, sessionId, entry) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kFileBrowserRouteName),
            builder: (_) =>
                TextFileViewerScreen(sessionId: sessionId, entry: entry),
          ),
        );
      },
    ),
  ]);
});
