// Reusable fullscreen "fill" viewer for embedded markdown media (#946, epic #944).
//
// EVERY embedded media item in the markdown viewer — inline images (`![](...)`)
// AND mermaid diagrams — renders inline at a sensible size and is TAP-TO-FILL:
// tapping pushes this route, where pinch-zoom + pan work.
//
// Two presentation modes (decided after the +76 device reports #949):
//   - IMAGE (default): a plain image child zooms via a Flutter [InteractiveViewer]
//     (panEnabled + scaleEnabled, min/max scale, double-tap to fit/reset). The
//     image is centred + contained and drawn at high [FilterQuality] so it stays
//     crisp when zoomed.
//   - SELF-ZOOMING (`selfZooming: true`): the child handles its OWN zoom + pan —
//     a platform WebView (mermaid). A Flutter InteractiveViewer can NOT drive a
//     PlatformView (it consumes the pointers), so wrapping it only made pan feel
//     sluggish and left the diagram top-aligned / un-centred (#949). We present
//     the child FULL-BLEED and defer every gesture to it; the WebView's built-in
//     zoom is crisp and the host page centres the diagram.
//
// Monochrome Material glyph for the close affordance (no emoji). Dark scrim.

import 'package:flutter/material.dart';

/// Pushes the shared [FillMediaViewer] route with [child] as the zoomable
/// surface. Returns when the user closes the viewer.
///
/// [selfZooming] = the child handles its OWN zoom + pan (a platform WebView,
/// whose built-in zoom is crisp and which a Flutter [InteractiveViewer] can't
/// drive anyway). For those we present the child full-bleed and defer all
/// gestures to it. Plain images (the default) get the [InteractiveViewer].
Future<void> showFillMediaViewer(
  BuildContext context, {
  required Widget child,
  String? label,
  bool selfZooming = false,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          FillMediaViewer(label: label, selfZooming: selfZooming, child: child),
    ),
  );
}

/// Fullscreen, dark-scrim media viewer. See the file header for the two modes.
class FillMediaViewer extends StatefulWidget {
  const FillMediaViewer({
    super.key,
    required this.child,
    this.label,
    this.selfZooming = false,
  });

  /// The media surface — an image widget, or a self-zooming diagram surface.
  final Widget child;

  /// Optional accessible label / app-bar-less title shown to the user.
  final String? label;

  /// When true the child owns its zoom/pan (WebView) — presented full-bleed
  /// without the [InteractiveViewer]. See the file header (#949).
  final bool selfZooming;

  @override
  State<FillMediaViewer> createState() => _FillMediaViewerState();
}

class _FillMediaViewerState extends State<FillMediaViewer> {
  final TransformationController _controller = TransformationController();
  TapDownDetails? _doubleTapDetails;

  static const double _minScale = 0.5;
  static const double _maxScale = 8.0;
  static const double _doubleTapScale = 2.5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _onDoubleTap() {
    // Already zoomed in → reset to fit. Otherwise zoom toward the tap point.
    if (_controller.value != Matrix4.identity()) {
      _controller.value = Matrix4.identity();
      return;
    }
    final pos = _doubleTapDetails?.localPosition;
    if (pos == null) return;
    _controller.value = Matrix4.identity()
      ..translateByDouble(
        -pos.dx * (_doubleTapScale - 1),
        -pos.dy * (_doubleTapScale - 1),
        0,
        1,
      )
      ..scaleByDouble(_doubleTapScale, _doubleTapScale, _doubleTapScale, 1);
  }

  /// The media surface. Self-zooming children (WebView) are full-bleed and own
  /// their gestures; images get the centred, crisp InteractiveViewer.
  Widget _buildSurface() {
    if (widget.selfZooming) {
      return Positioned.fill(
        key: const Key('fill-media-self-zooming'),
        child: widget.child,
      );
    }
    return Positioned.fill(
      child: GestureDetector(
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: _onDoubleTap,
        child: InteractiveViewer(
          key: const Key('fill-media-interactive-viewer'),
          transformationController: _controller,
          panEnabled: true,
          scaleEnabled: true,
          minScale: _minScale,
          maxScale: _maxScale,
          // Unbounded margin so the user can pan a zoomed image fully past the
          // viewport edges.
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: Center(child: widget.child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('fill-media-viewer'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            _buildSurface(),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('fill-media-close'),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
