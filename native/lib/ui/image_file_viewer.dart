// In-app image viewer (#1093, slice of #635).
//
// Opened from the SFTP file browser when a raster image (png/jpg/gif/webp/…)
// is tapped, via the [fileViewerRegistryProvider] — the standalone counterpart
// to the markdown-embedded fill viewer (#946). The image is rendered in a
// WebView: the raw bytes (fetched over the session's SFTP with the SAME seam
// the markdown inline images use, [SftpImageFetcher]) are embedded as a
// `data:` URI inside a tiny HTML shell that centres + contains the picture on a
// dark scrim. Animated GIF / APNG animate natively.
//
// Pinch-zoom + pan are the WebView's own (#949 selfZooming shape): the surface
// is full-bleed and NEVER wrapped in an InteractiveViewer (an InteractiveViewer
// cannot drive a PlatformView — they fight). The HTML viewport meta allows
// user scaling.
//
// v1 uses a data: URI (whole image in the HTML string). The [SftpImageFetcher]
// per-asset cap bounds it; a very large image could be moved to the loopback
// server the HTML viewer uses if it ever matters.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/image_detect.dart';
import '../services/session_messages.dart';
import '../services/sftp_image_fetcher.dart';
import '../services/viewer_file_actions.dart';
import 'file_browser_screen.dart';
import 'file_viewer_actions.dart';

/// Builds the live render surface for the image [html] shell. Swapped out in
/// widget tests (no platform WebView there) via [imageWebViewBuilder] — the
/// public [ImageFileViewerScreen] type stays stable so routing assertions hold.
typedef ImageWebViewBuilder = Widget Function(String html);

Widget _defaultImageWebView(String html) => _ImageWebView(html: html);

/// Seam: production builds a real WebView; tests override this to a stub so the
/// screen mounts without a platform channel.
ImageWebViewBuilder imageWebViewBuilder = _defaultImageWebView;

/// Test-only handle to the production builder, so a test can restore
/// [imageWebViewBuilder] after overriding it with a stub.
@visibleForTesting
ImageWebViewBuilder get defaultImageWebViewBuilderForTest => _defaultImageWebView;

/// Wraps the image [bytes] of type [mime] into a self-contained HTML shell that
/// centres + contains the picture on a dark scrim and permits pinch-zoom. Pure
/// so it's unit-testable. Styling lives in a `<style>` block (CSS, not inline
/// style attributes, per project style).
String buildImageHtml(List<int> bytes, String mime) {
  final b64 = base64Encode(bytes);
  return '<!doctype html>'
      '<html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1, '
      'minimum-scale=1, maximum-scale=6, user-scalable=yes">'
      '<style>'
      'html,body{margin:0;height:100%;background:#111;}'
      'body{display:flex;align-items:center;justify-content:center;}'
      'img{max-width:100%;max-height:100%;object-fit:contain;}'
      '</style></head>'
      '<body><img src="data:$mime;base64,$b64" alt=""></body></html>';
}

/// Full-screen image route for a single remote [entry] on [sessionId].
class ImageFileViewerScreen extends ConsumerStatefulWidget {
  const ImageFileViewerScreen({
    super.key,
    required this.sessionId,
    required this.entry,
  });

  final String sessionId;
  final SftpEntry entry;

  @override
  ConsumerState<ImageFileViewerScreen> createState() =>
      _ImageFileViewerScreenState();
}

enum _Phase { loading, ready, error }

class _ImageFileViewerScreenState extends ConsumerState<ImageFileViewerScreen> {
  _Phase _phase = _Phase.loading;
  String? _errorMessage;
  String? _html;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final fetcher = ref.read(sftpImageFetcherProvider);
    try {
      final bytes = await fetcher.fetch(widget.sessionId, widget.entry.path);
      if (!mounted) return;
      setState(() {
        _html = buildImageHtml(bytes, imageMimeForName(widget.entry.name));
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = "Couldn't open ${widget.entry.name}";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name, overflow: TextOverflow.ellipsis),
        actions: [
          // #1038: Download + Share from any open preview.
          FileViewerActions(
            source: RemoteFileSource(
              sessionId: widget.sessionId,
              entry: widget.entry,
            ),
          ),
          // #855: one-tap return to the terminal (collapses the whole
          // browser/viewer stack). Monochrome Material glyph, rightmost.
          IconButton(
            key: const Key('image-viewer-close-to-terminal'),
            tooltip: 'Close — back to terminal',
            icon: const Icon(Icons.close),
            onPressed: () => dismissFileBrowserStack(context),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.loading:
        return const Center(
          key: Key('image-viewer-loading'),
          child: CircularProgressIndicator(),
        );
      case _Phase.error:
        return Center(
          key: const Key('image-viewer-error'),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorMessage ?? 'Could not open this file',
              textAlign: TextAlign.center,
            ),
          ),
        );
      case _Phase.ready:
        // Full-bleed; the WebView owns zoom/pan (#949 selfZooming shape).
        return SizedBox.expand(
          key: const Key('image-webview-surface'),
          child: imageWebViewBuilder(_html!),
        );
    }
  }
}

/// The real WebView-backed image surface: zoom on, JS off (a static picture),
/// dark background so letterboxing matches the shell scrim.
class _ImageWebView extends StatefulWidget {
  const _ImageWebView({required this.html});

  final String html;

  @override
  State<_ImageWebView> createState() => _ImageWebViewState();
}

class _ImageWebViewState extends State<_ImageWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..enableZoom(true)
      ..setBackgroundColor(const Color(0xFF111111))
      ..loadHtmlString(widget.html);
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
