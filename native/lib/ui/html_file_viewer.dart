// In-app rendered HTML viewer (#1037, epic #944).
//
// Opened from the SFTP file browser when a `.html` / `.htm` file is tapped
// (via the [fileViewerRegistryProvider], routed BEFORE the generic monospace
// text viewer). Instead of showing raw source, the page is RENDERED in a
// WebView that loads `http://127.0.0.1:<port>/<name>.html` from a per-viewer
// [HtmlLoopbackServer]: relative references inside the page (linked CSS,
// images, scripts — including nested dirs) resolve against the file's REMOTE
// directory, fetched over the session's SFTP on demand. See
// html_loopback_server.dart for the full security posture (127.0.0.1-only,
// random port, serves only the opened tree, viewer-scoped lifetime).
//
// Navigation policy (v1, simple): same-loopback-origin loads are allowed;
// ANY other navigation (external links, other schemes) is blocked with a
// toast. JS is enabled — wireframes / self-contained pages need it.
//
// Pinch-zoom + pan are the WebView's own (#949 selfZooming shape): the
// surface is full-bleed and NEVER wrapped in an InteractiveViewer (an
// InteractiveViewer cannot drive a PlatformView — they fight). Dark pages
// render as the page dictates — no forced theming.
//
// The app bar's "view source" pushes the EXISTING monospace text viewer for
// the same entry (read-only), so the raw-source escape hatch is one tap away.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/html_loopback_server.dart';
import '../services/session_messages.dart';
import '../services/sftp_image_fetcher.dart';
import 'file_browser_screen.dart';
import 'text_file_viewer.dart';
import 'top_toast.dart';

/// Builds the live render surface for the loopback [uri]. Swapped out in
/// widget tests (no platform WebView there) via [htmlWebViewBuilder] — the
/// public [HtmlFileViewerScreen] type stays stable so routing assertions hold.
/// [onBlocked] is invoked with the URL of any blocked (non-loopback)
/// navigation.
typedef HtmlWebViewBuilder =
    Widget Function(Uri uri, void Function(String url) onBlocked);

Widget _defaultHtmlWebView(Uri uri, void Function(String url) onBlocked) =>
    _HtmlWebView(uri: uri, onBlocked: onBlocked);

/// Seam: production builds a real WebView; tests override this to a stub so
/// the screen mounts without a platform channel.
HtmlWebViewBuilder htmlWebViewBuilder = _defaultHtmlWebView;

/// Test-only handle to the production builder, so a test can restore
/// [htmlWebViewBuilder] after overriding it with a stub.
@visibleForTesting
HtmlWebViewBuilder get defaultHtmlWebViewBuilderForTest => _defaultHtmlWebView;

/// Test-only handle to the screen's live loopback server (the most recently
/// started one), so integration tests can probe the resolver end-to-end
/// (asset 200s, escape 404s) without reaching into private state.
@visibleForTesting
HtmlLoopbackServer? debugLastHtmlLoopbackServer;

/// Full-screen rendered HTML route for a single remote [entry] on [sessionId].
class HtmlFileViewerScreen extends ConsumerStatefulWidget {
  const HtmlFileViewerScreen({
    super.key,
    required this.sessionId,
    required this.entry,
  });

  final String sessionId;
  final SftpEntry entry;

  @override
  ConsumerState<HtmlFileViewerScreen> createState() =>
      _HtmlFileViewerScreenState();
}

enum _Phase { starting, ready, error }

class _HtmlFileViewerScreenState extends ConsumerState<HtmlFileViewerScreen> {
  _Phase _phase = _Phase.starting;
  String? _errorMessage;
  HtmlLoopbackServer? _server;
  Uri? _uri;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    // The loopback server's byte source is the session's SFTP image fetcher —
    // raw bytes, no binary-reject, per-asset cap — the same seam the markdown
    // viewer's inline images use (#946). Reads happen on demand per request.
    final fetcher = ref.read(sftpImageFetcherProvider);
    final server = HtmlLoopbackServer(
      rootDir: dirnamePosix(widget.entry.path),
      fetch: (remotePath) => fetcher.fetch(widget.sessionId, remotePath),
    );
    try {
      await server.start();
    } catch (e) {
      if (!mounted) {
        unawaited(server.close());
        return;
      }
      setState(() {
        _phase = _Phase.error;
        _errorMessage = e.toString();
      });
      return;
    }
    if (!mounted) {
      unawaited(server.close());
      return;
    }
    _server = server;
    debugLastHtmlLoopbackServer = server;
    setState(() {
      _uri = server.uriFor(widget.entry.name);
      _phase = _Phase.ready;
    });
  }

  @override
  void dispose() {
    // Viewer-scoped lifetime: the loopback port closes with the route.
    unawaited(_server?.close());
    if (identical(debugLastHtmlLoopbackServer, _server)) {
      debugLastHtmlLoopbackServer = null;
    }
    super.dispose();
  }

  void _onBlocked(String url) {
    if (!mounted) return;
    showTopToast(context, 'Blocked external link');
  }

  void _openSource() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: kFileBrowserRouteName),
        builder: (_) => TextFileViewerScreen(
          sessionId: widget.sessionId,
          entry: widget.entry,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name, overflow: TextOverflow.ellipsis),
        actions: [
          // View source: the existing monospace text viewer for this entry.
          // Monochrome Material glyph (no emoji).
          IconButton(
            key: const Key('html-view-source'),
            tooltip: 'View source',
            icon: const Icon(Icons.code),
            onPressed: _openSource,
          ),
          // #855: one-tap return to the terminal (collapses the whole
          // browser/viewer stack) — conventional top-right close, rightmost.
          IconButton(
            key: const Key('html-viewer-close-to-terminal'),
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
      case _Phase.starting:
        return const Center(
          key: Key('html-viewer-loading'),
          child: CircularProgressIndicator(),
        );
      case _Phase.error:
        return Center(
          key: const Key('html-viewer-error'),
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
          key: const Key('html-webview-surface'),
          child: htmlWebViewBuilder(_uri!, _onBlocked),
        );
    }
  }
}

/// The real WebView-backed renderer: JS on, zoom on, navigation locked to the
/// loopback origin.
class _HtmlWebView extends StatefulWidget {
  const _HtmlWebView({required this.uri, required this.onBlocked});

  final Uri uri;
  final void Function(String url) onBlocked;

  @override
  State<_HtmlWebView> createState() => _HtmlWebViewState();
}

class _HtmlWebViewState extends State<_HtmlWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    final origin = 'http://${widget.uri.host}:${widget.uri.port}/';
    _controller = WebViewController()
      // JS enabled: wireframes / self-contained pages need it. The page can
      // only reach the loopback tree (navigation locked below; the server
      // itself only resolves under the opened directory).
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // v1 policy: same-loopback-origin only; everything else blocked
            // with a toast (no system-browser handoff yet).
            if (request.url.startsWith(origin)) {
              return NavigationDecision.navigate;
            }
            widget.onBlocked(request.url);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(widget.uri);
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
