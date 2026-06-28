// Offline mermaid diagram renderer for the in-app markdown viewer (#942, #944).
//
// The markdown viewer routes ```mermaid fenced blocks here (see
// markdown_file_viewer.dart's MermaidElementBuilder). We render the diagram with
// mermaid.js inside a WebView, fully OFFLINE: mermaid.min.js and the render host
// are bundled Flutter assets (native/assets/mermaid/) — no CDN, no network ever.
//
// #944 directive: leverage a WebView for media it can safely render offline
// instead of writing a per-type Dart renderer. mermaid is the first instance;
// this file is the reusable harness pattern (load an asset host, postMessage a
// measured height back, size the surface to the content).
//
// HARD INVARIANT (#944): the rendered diagram must be PINCH-ZOOMABLE + PANNABLE.
// We get that from the Android WebView's BUILT-IN zoom (webview_flutter_android
// enables setBuiltInZoomControls by default) plus user-scalable=yes in the host
// viewport and controller.enableZoom(true). An InteractiveViewer can NOT wrap a
// platform WebView (the PlatformView consumes the pointer events before the
// gesture arena), so in-webview zoom is the correct mechanism.
//
// Graceful fallback: invalid mermaid (or a missing/init-failed bundle) never
// crashes the viewer — the JS posts {type:'error'} and we show the verbatim
// source plus a small note, mirroring the raw/source toggle.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'fill_media_viewer.dart';

/// Builds the live render surface for a mermaid [source]. Swapped out in widget
/// tests (which have no platform WebView) via [mermaidWebViewBuilder] — the
/// public [MermaidDiagramView] type stays stable so routing assertions hold.
typedef MermaidWebViewBuilder = Widget Function(String source);

Widget _defaultMermaidWebView(String source) => _MermaidWebView(source: source);

/// Seam: production builds a real WebView; tests override this to a stub so
/// `find.byType(MermaidDiagramView)` works without a platform channel.
MermaidWebViewBuilder mermaidWebViewBuilder = _defaultMermaidWebView;

/// Test-only handle to the production builder, so a test can restore
/// [mermaidWebViewBuilder] after overriding it with a stub.
@visibleForTesting
MermaidWebViewBuilder get defaultMermaidWebViewBuilderForTest =>
    _defaultMermaidWebView;

/// Builds the FULLSCREEN mermaid surface shown inside the tap-to-fill viewer
/// (#946). Separate seam from the inline surface so tests can stub it without a
/// platform channel. On device this is a WebView that FILLS the route, where its
/// built-in pinch-zoom works (it is no longer nested in a scroll view).
typedef MermaidFillBuilder = Widget Function(String source);

Widget _defaultMermaidFill(String source) =>
    _MermaidWebView(source: source, fill: true);

/// Seam: production builds a fullscreen WebView; tests override this to a stub.
MermaidFillBuilder mermaidFillBuilder = _defaultMermaidFill;

/// Test-only handle to the production fill builder.
@visibleForTesting
MermaidFillBuilder get defaultMermaidFillBuilderForTest => _defaultMermaidFill;

/// Inline-rendered mermaid diagram. Returned by the markdown viewer's
/// `MermaidElementBuilder` in place of a ```mermaid code block.
///
/// #946: the inline diagram is a PREVIEW — it no longer relies on the WebView's
/// in-place built-in zoom (unreliable nested in a scroll view, gesture arena).
/// A transparent tap overlay ABOVE the platform WebView captures the tap and
/// pushes the shared [FillMediaViewer] with a fullscreen diagram where
/// pinch/pan/zoom work.
class MermaidDiagramView extends StatelessWidget {
  const MermaidDiagramView({super.key, required this.source});

  /// The raw mermaid source from inside the fenced block (without the fence).
  final String source;

  void _openFill(BuildContext context) {
    showFillMediaViewer(context, child: mermaidFillBuilder(source));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('mermaid-diagram-view'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          mermaidWebViewBuilder(source),
          // Transparent layer above the WebView so the tap reaches Flutter
          // (the platform view otherwise consumes pointers).
          Positioned.fill(
            child: GestureDetector(
              key: const Key('mermaid-tap-to-fill'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _openFill(context),
            ),
          ),
          const IgnorePointer(
            child: Padding(
              padding: EdgeInsets.all(4),
              child: _MermaidZoomBadge(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small monochrome "expand" badge hinting tap-to-fill (no emoji).
class _MermaidZoomBadge extends StatelessWidget {
  const _MermaidZoomBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.zoom_out_map, size: 16, color: Colors.white),
    );
  }
}

/// The real WebView-backed renderer. Loads the bundled offline host, hands it
/// the source after page load, and sizes itself to the diagram's measured
/// height (posted back over the [_channelName] JS channel).
class _MermaidWebView extends StatefulWidget {
  const _MermaidWebView({required this.source, this.fill = false});

  final String source;

  /// When true the surface FILLS its parent (the fullscreen fill viewer) instead
  /// of sizing to the measured diagram height — built-in zoom is the zoom path.
  final bool fill;

  @override
  State<_MermaidWebView> createState() => _MermaidWebViewState();
}

const String _channelName = 'MermaidChannel';
const String _hostAsset = 'assets/mermaid/mermaid_host.html';
const double _initialHeight = 240;

class _MermaidWebViewState extends State<_MermaidWebView> {
  late final WebViewController _controller;
  double _height = _initialHeight;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..enableZoom(true)
      ..addJavaScriptChannel(_channelName, onMessageReceived: _onChannelMessage)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => _renderSource()),
      );
    // loadFlutterAsset serves the host from the asset bundle and sets the base
    // URL so the sibling <script src="mermaid.min.js"> resolves offline.
    _controller.loadFlutterAsset(_hostAsset);
  }

  Future<void> _renderSource() async {
    // jsonEncode produces a safe JS string literal for the source.
    final encoded = jsonEncode(widget.source);
    await _controller.runJavaScript('window.renderMermaid($encoded);');
  }

  void _onChannelMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final type = payload['type'];
    if (type == 'size') {
      final h = (payload['height'] as num?)?.toDouble();
      if (h != null && h > 0) setState(() => _height = h);
    } else if (type == 'error') {
      setState(() => _error = payload['message']?.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _MermaidFallback(source: widget.source, error: _error);
    }
    if (widget.fill) {
      // Fullscreen fill viewer: occupy the whole route so the WebView's built-in
      // pinch-zoom is the zoom path (no scroll-vs-zoom contention).
      return SizedBox.expand(
        key: const Key('mermaid-webview-surface-fill'),
        child: WebViewWidget(controller: _controller),
      );
    }
    return SizedBox(
      key: const Key('mermaid-webview-surface'),
      height: _height,
      width: double.infinity,
      child: WebViewWidget(controller: _controller),
    );
  }
}

/// Graceful degradation: show the verbatim mermaid source plus a small note when
/// the diagram can't be rendered. Never throws — the viewer stays usable.
class _MermaidFallback extends StatelessWidget {
  const _MermaidFallback({required this.source, this.error});

  final String source;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono =
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['RobotoMono', 'monospace'],
        ) ??
        const TextStyle(fontFamily: 'monospace');
    return Container(
      key: const Key('mermaid-fallback'),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Could not render mermaid diagram',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(source, style: mono),
          ),
        ],
      ),
    );
  }
}
