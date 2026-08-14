// In-app rendered HTML viewer (#1037, hardened #1107).
//
// Opened from the SFTP file browser when a `.html` / `.htm` file is tapped
// (via the [fileViewerRegistryProvider], routed BEFORE the generic monospace
// text viewer). Instead of showing raw source, the page is RENDERED — but as a
// single self-contained document, NOT off a live server.
//
// SECURITY (#1107, Approach A): the document + every asset it references is
// fetched over the session's SFTP and folded into ONE string by [buildSafeHtml]
// — active content stripped, assets inlined as `data:` URIs, a
// `default-src 'none'` meta-CSP prepended. That string is handed to a
// JS-DISABLED WebView via `loadHtmlString` (null baseUrl → opaque origin). There
// is no origin, no socket, no network egress: a hostile `.html` can no longer
// read `~/.ssh/id_rsa` same-origin and POST it out (the old loopback server that
// served the whole opened subtree with no auth is gone). The only capability
// lost is running the page's own JS — read / copy / act need none.
//
// Links: real navigations are blocked and handed to [htmlLinkOpener], which
// launches the system browser (externalApplication — same idiom as the terminal
// and markdown URL handlers). Only the initial in-memory/data load is allowed.
//
// Pinch-zoom + pan are the WebView's own (#949 selfZooming shape): the surface
// is full-bleed and NEVER wrapped in an InteractiveViewer (an InteractiveViewer
// cannot drive a PlatformView — they fight). The app bar's "view source" pushes
// the EXISTING monospace text viewer for the same entry (read-only).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/html_inliner.dart';
import '../services/session_messages.dart';
import '../services/sftp_image_fetcher.dart';
import '../services/text_file_fetcher.dart';
import '../services/viewer_file_actions.dart';
import 'file_browser_screen.dart';
import 'file_viewer_actions.dart';
import 'text_file_viewer.dart';

/// Opens a blocked in-page navigation [url] in the system browser
/// (externalApplication). Injected as a mutable seam (mirrors
/// [htmlWebViewBuilder]) so widget tests spy on launches without a platform
/// channel.
typedef HtmlLinkOpener = Future<void> Function(String url);

Future<void> _defaultOpenHtmlLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Seam: production launches the system browser; tests override this to a spy.
HtmlLinkOpener htmlLinkOpener = _defaultOpenHtmlLink;

/// Test-only handle to the production opener, so a test can restore
/// [htmlLinkOpener] after overriding it.
@visibleForTesting
HtmlLinkOpener get defaultHtmlLinkOpenerForTest => _defaultOpenHtmlLink;

/// Builds the render surface for the self-contained [safeHtml]. Swapped out in
/// widget tests (no platform WebView there) via [htmlWebViewBuilder] — the
/// public [HtmlFileViewerScreen] type stays stable so routing assertions hold.
/// [onLink] receives the URL of any blocked (real) navigation.
typedef HtmlWebViewBuilder =
    Widget Function(String safeHtml, HtmlLinkOpener onLink);

Widget _defaultHtmlWebView(String safeHtml, HtmlLinkOpener onLink) =>
    _HtmlWebView(safeHtml: safeHtml, onLink: onLink);

/// Seam: production builds a real WebView; tests override this to a stub so the
/// screen mounts without a platform channel.
HtmlWebViewBuilder htmlWebViewBuilder = _defaultHtmlWebView;

/// Test-only handle to the production builder, so a test can restore
/// [htmlWebViewBuilder] after overriding it with a stub.
@visibleForTesting
HtmlWebViewBuilder get defaultHtmlWebViewBuilderForTest => _defaultHtmlWebView;

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

enum _Phase { building, ready, error }

class _HtmlFileViewerScreenState extends ConsumerState<HtmlFileViewerScreen> {
  _Phase _phase = _Phase.building;
  String? _errorMessage;
  String? _safeHtml;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    // The document is fetched as text; its assets over the SFTP image fetcher
    // (raw bytes, per-asset cap) — the same seams the text and markdown viewers
    // use. Everything is inlined into one self-contained document.
    final textFetcher = ref.read(textFileFetcherProvider);
    final assetFetcher = ref.read(sftpImageFetcherProvider);
    try {
      final source = await textFetcher.fetch(widget.sessionId, widget.entry);
      final safe = await buildSafeHtml(
        source: source,
        docRemotePath: widget.entry.path,
        fetchAsset: (remotePath) =>
            assetFetcher.fetch(widget.sessionId, remotePath),
      );
      if (!mounted) return;
      setState(() {
        _safeHtml = safe;
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = e.toString();
      });
    }
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
          // #1038: Download + Share from any open preview.
          FileViewerActions(
            source: RemoteFileSource(
              sessionId: widget.sessionId,
              entry: widget.entry,
            ),
          ),
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
      case _Phase.building:
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
          child: htmlWebViewBuilder(_safeHtml!, htmlLinkOpener),
        );
    }
  }
}

/// The real WebView-backed renderer: JS OFF, zoom on, no origin. Only the
/// initial in-memory (`loadHtmlString`) load is allowed; every real navigation
/// is blocked and handed to [onLink] for the system browser.
class _HtmlWebView extends StatefulWidget {
  const _HtmlWebView({required this.safeHtml, required this.onLink});

  final String safeHtml;
  final HtmlLinkOpener onLink;

  @override
  State<_HtmlWebView> createState() => _HtmlWebViewState();
}

class _HtmlWebViewState extends State<_HtmlWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final url = request.url;
            // The initial `loadHtmlString` document loads as about:blank / a
            // data: URL — allow only that; hand every real navigation to the
            // system browser.
            if (url == 'about:blank' ||
                url.startsWith('about:') ||
                url.startsWith('data:')) {
              return NavigationDecision.navigate;
            }
            unawaited(widget.onLink(url));
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadHtmlString(widget.safeHtml);
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
