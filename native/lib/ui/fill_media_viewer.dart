// Reusable fullscreen "fill" viewer for embedded markdown media (#946, epic #944).
//
// EVERY embedded media item in the markdown viewer — inline images (`![](...)`)
// AND mermaid diagrams — renders inline at a sensible size and is TAP-TO-FILL:
// tapping pushes this route, where pinch-zoom + pan are FORCE-enabled.
//
// Why a dedicated route instead of in-place pinch/pan: a PlatformView (the
// mermaid WebView) nested inside the scrolling markdown wins the gesture arena,
// so an in-place InteractiveViewer never receives the scale/pan pointers (the
// +75 mermaid built-in zoom didn't work on device for exactly this reason). A
// fullscreen route removes the scroll-vs-zoom contention:
//   - a plain image child zooms via this [InteractiveViewer] (panEnabled +
//     scaleEnabled, min/max scale, double-tap to fit/reset);
//   - a fullscreen WebView child (mermaid) zooms via its own built-in zoom,
//     which works once it is no longer nested in a scroll view. The
//     InteractiveViewer still wraps it for a consistent close/scrim chrome.
//
// Monochrome Material glyph for the close affordance (no emoji). Dark scrim.

import 'package:flutter/material.dart';

/// Pushes the shared [FillMediaViewer] route with [child] as the zoomable
/// surface. Returns when the user closes the viewer.
Future<void> showFillMediaViewer(
  BuildContext context, {
  required Widget child,
  String? label,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FillMediaViewer(label: label, child: child),
    ),
  );
}

/// Fullscreen, dark-scrim media viewer. The single [child] is presented inside
/// an [InteractiveViewer] with pinch-zoom + pan FORCED on. Double-tap toggles
/// between fit (identity) and a 2.5× zoom centred on the tap point.
class FillMediaViewer extends StatefulWidget {
  const FillMediaViewer({super.key, required this.child, this.label});

  /// The media surface — an image widget, or a fullscreen diagram surface.
  final Widget child;

  /// Optional accessible label / app-bar-less title shown to the user.
  final String? label;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('fill-media-viewer'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
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
                  // Unbounded margin so the user can pan a zoomed image fully
                  // past the viewport edges.
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: Center(child: widget.child),
                ),
              ),
            ),
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
