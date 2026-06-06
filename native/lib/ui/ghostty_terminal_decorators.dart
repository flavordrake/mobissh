// ghostty_terminal_decorators.dart — pluggable per-pattern decorator framework
// for the forked flterm terminal (#767 Slice B).
//
// Slice A moved structured-text DETECTION + persistent cell-sequence anchoring
// INTO the fork: the terminal scans its own cells, anchors matches in absolute
// buffer coords, and re-anchors them across scroll/wrap/resize/eviction by
// re-scanning (no app-side geometry). Slice B builds the RENDERING seam on top:
// the fork EXPOSES the anchors + a live geometry resolver
// (`controller.anchors` / `controller.anchorRects`), and THIS file injects a
// per-pattern DECORATOR over them — so the fork never bakes in one paint style
// and each rich interaction (URL, and FUTURE file paths / commit shas / issue
// refs) gets its own treatment without the fork changing.
//
// The default `url` decorator is a BUBBLE/CHIP: a rounded-rect OUTLINE hugging
// the matched cells (joined visually across soft-wrap rows) in the theme accent
// color. It is an OUTLINE (never an opaque fill over the glyphs — that hid the
// URL text, the bug the Slice B painter fix also addresses), so the URL stays
// readable and the affordance is unambiguous and tappable. Tap/long-press are
// still routed by the gesture router (`controller.matchAt` → copy / open); the
// decorator is the VISUAL layer only.
//
// Extending: register a new TextPattern on the controller (detection) AND a
// `GhosttyTerminalDecorator` here (rendering). The next consumers are file
// paths (#570) and commit shas / issue refs (OSC8, #631) — each a different
// glyph/chip; see [GhosttyDecoratorRegistry.defaults].

import 'package:flutter/widgets.dart';
import 'package:flterm/flterm.dart';

/// The id of the built-in URL pattern/decorator. Mirrors the pattern id the
/// view registers on the controller so the registry can route URL anchors here.
const String kGhosttyUrlPatternId = 'url';

/// The id of the OSC-8 HYPERLINK pattern/decorator (#767 Slice B). The PRIMARY,
/// exact URL source: the terminal reads the OSC-8 URI off its own cells (no
/// regex), so a wrapped link spans all its rows and the payload is the exact
/// full URI. Its anchor renders the SAME bubble affordance as a regex URL.
const String kGhosttyOsc8PatternId = 'osc8';

/// The id of the absolute FILE PATH pattern/decorator (#778, paths Slice 1).
/// Mirrors the pattern id the view registers so the registry routes path anchors
/// to [PathDecorator] (a distinct treatment from the URL bubble).
const String kGhosttyPathPatternId = 'path';

/// Per-anchor render input handed to a [GhosttyTerminalDecorator] (#767 B).
///
/// [rects] are the anchor's CURRENT viewport pixel rects (one per visible
/// soft-wrap row segment), already resolved from the live geometry — empty when
/// the anchor is scrolled off-screen, in which case the decorator draws nothing.
/// [payload] is what the cells represent (e.g. the URL string). [color] is the
/// theme accent the decorator paints in.
@immutable
class GhosttyDecoratedAnchor {
  const GhosttyDecoratedAnchor({
    required this.payload,
    required this.rects,
    required this.color,
  });

  final Object payload;
  final List<Rect> rects;
  final Color color;
}

/// A pluggable per-pattern visual decorator over detected anchors (#767 B).
///
/// One decorator per pattern id; [build] returns a paint-only widget drawn over
/// the terminal grid for the given anchors. Returning an empty list of anchors
/// (all off-screen) yields nothing to draw.
abstract class GhosttyTerminalDecorator {
  const GhosttyTerminalDecorator();

  /// The [TextPattern.id] this decorator renders (e.g. `url`).
  String get patternId;

  /// Build the overlay for [anchors] (already resolved to viewport rects).
  Widget build(BuildContext context, List<GhosttyDecoratedAnchor> anchors);
}

/// Registry mapping a pattern id to its [GhosttyTerminalDecorator] (#767 B).
///
/// Adding a future rich interaction = register a [TextPattern] on the controller
/// (detection) and a decorator here (rendering). The view looks the decorator up
/// by each anchor's [StructuredAnchor.patternId].
class GhosttyDecoratorRegistry {
  GhosttyDecoratorRegistry(Iterable<GhosttyTerminalDecorator> decorators)
    : _byPattern = {for (final d in decorators) d.patternId: d};

  /// The default registry: the URL bubble. FUTURE consumers (file paths #570,
  /// commit shas / issue refs #631) register additional decorators here, each
  /// with its own glyph/chip styling, alongside a matching controller pattern.
  factory GhosttyDecoratorRegistry.defaults() {
    return GhosttyDecoratorRegistry(const [
      UrlBubbleDecorator(),
      // #767 Slice B: an OSC-8 hyperlink anchor renders the SAME bubble as a
      // regex URL — same affordance, exact full URI behind it.
      UrlBubbleDecorator(patternId: kGhosttyOsc8PatternId),
      // #778 paths Slice 1: a file-path anchor gets a DISTINCT treatment — a
      // leading folder glyph + a thin dotted underline, NOT the URL bubble.
      PathDecorator(),
    ]);
  }

  final Map<String, GhosttyTerminalDecorator> _byPattern;

  /// The decorator for [patternId], or null when none is registered.
  GhosttyTerminalDecorator? forPattern(String patternId) =>
      _byPattern[patternId];

  /// The registered pattern ids (for tests / introspection).
  Iterable<String> get patternIds => _byPattern.keys;
}

/// The default URL decorator: a rounded-rect OUTLINE BUBBLE hugging the URL's
/// cells, joined visually across wrap rows (#767 Slice B). Never an opaque fill.
class UrlBubbleDecorator extends GhosttyTerminalDecorator {
  /// [patternId] selects which pattern's anchors this bubble renders — the
  /// regex `url` pattern by default, or the OSC-8 `osc8` source (#767 Slice B),
  /// which draws the identical bubble over the exact-URI hyperlink anchors.
  const UrlBubbleDecorator({this.patternId = kGhosttyUrlPatternId});

  @override
  final String patternId;

  @override
  Widget build(BuildContext context, List<GhosttyDecoratedAnchor> anchors) {
    return IgnorePointer(
      // Paint-only — taps/long-presses fall through to the gesture router, which
      // owns hit-test (controller.matchAt) + copy/open.
      child: CustomPaint(
        painter: _UrlBubblePainter(anchors),
        size: Size.infinite,
      ),
    );
  }
}

/// Paints one rounded-rect outline bubble per URL anchor, joining its per-row
/// rects so a soft-wrapped URL reads as a single chip stack hugging its cells.
class _UrlBubblePainter extends CustomPainter {
  _UrlBubblePainter(this.anchors);

  final List<GhosttyDecoratedAnchor> anchors;

  /// Outline stroke width and how much the bubble is inflated beyond the raw
  /// cell rects, in logical px — a hair of breathing room so the outline hugs
  /// without clipping the glyphs.
  static const double _stroke = 1.5;
  static const double _inset = 1.0;
  static const double _radius = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    for (final anchor in anchors) {
      if (anchor.rects.isEmpty) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = anchor.color
        ..isAntiAlias = true;
      // One rounded outline per row segment (a wrapped URL → a chip per row),
      // each inflated a touch and clamped non-negative so a zero-size rect can't
      // invert. Drawing per-segment (not one merged path) keeps each wrap row's
      // chip hugging exactly its cells.
      for (final rect in anchor.rects) {
        final bubble = rect.inflate(_inset);
        if (bubble.width <= 0 || bubble.height <= 0) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(bubble, const Radius.circular(_radius)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _UrlBubblePainter old) {
    // Repaint whenever the anchors (rects/color/payload) differ. The list is
    // rebuilt each frame from the live geometry, so identity is enough to catch
    // scroll/resize/detection changes cheaply.
    if (identical(old.anchors, anchors)) return false;
    if (old.anchors.length != anchors.length) return true;
    for (var i = 0; i < anchors.length; i++) {
      final a = anchors[i];
      final b = old.anchors[i];
      if (a.color != b.color || a.payload != b.payload) return true;
      if (a.rects.length != b.rects.length) return true;
      for (var j = 0; j < a.rects.length; j++) {
        if (a.rects[j] != b.rects[j]) return true;
      }
    }
    return false;
  }
}

/// The file-PATH decorator (#778, paths Slice 1) — DISTINCT from the URL bubble.
///
/// A path anchor must NOT reuse the URL's outline bubble (so the two affordances
/// read differently) and must avoid the two paints the fork's painter notes are
/// wrong for text: an opaque BACKGROUND FILL (hides the glyphs) and a SOLID
/// UNDERLINE (collides with SGR-4 underline). Instead it draws a leading
/// monochrome FOLDER glyph in the anchor color (memory
/// feedback_monochrome_icons_no_emoji — Material icon, currentColor, never an
/// emoji) plus a thin DOTTED underline in a faded secondary accent. Paint-only;
/// taps/long-presses fall through to the gesture router.
class PathDecorator extends GhosttyTerminalDecorator {
  const PathDecorator({this.patternId = kGhosttyPathPatternId});

  @override
  final String patternId;

  @override
  Widget build(BuildContext context, List<GhosttyDecoratedAnchor> anchors) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _PathPainter(anchors),
        size: Size.infinite,
      ),
    );
  }
}

/// Paints each path anchor: a leading folder glyph at the first row segment and a
/// thin dotted underline under every row segment.
class _PathPainter extends CustomPainter {
  _PathPainter(this.anchors);

  final List<GhosttyDecoratedAnchor> anchors;

  /// Underline offset below the cell baseline-ish bottom, stroke width, the
  /// dotted dash/gap, and the folder-glyph size cap, in logical px.
  static const double _underlineGap = 1.0;
  static const double _stroke = 1.2;
  static const double _dash = 2.0;
  static const double _space = 2.0;
  static const double _glyphMaxSize = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    for (final anchor in anchors) {
      if (anchor.rects.isEmpty) continue;
      // Secondary accent: a faded version of the anchor color so the path reads
      // as DISTINCT from the (full-strength outline) URL bubble.
      final underline = Paint()
        ..color = anchor.color.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
      for (final rect in anchor.rects) {
        if (rect.width <= 0 || rect.height <= 0) continue;
        final y = rect.bottom + _underlineGap;
        // Dotted underline: short dashes left→right under the row segment.
        var x = rect.left;
        while (x < rect.right) {
          final end = (x + _dash).clamp(rect.left, rect.right);
          canvas.drawLine(Offset(x, y), Offset(end, y), underline);
          x += _dash + _space;
        }
      }
      // Leading folder glyph at the first (top-most) row segment, sized to the
      // row height but capped so it never dominates.
      final first = anchor.rects.first;
      final glyphSize = first.height.clamp(8.0, _glyphMaxSize);
      _paintFolderGlyph(canvas, first, glyphSize, anchor.color);
    }
  }

  /// Draw a monochrome folder OUTLINE glyph to the LEFT of the path's first cell
  /// rect, in the anchor color. Hand-drawn outline (no font dependency) so it is
  /// theme-compliant currentColor and never an emoji.
  void _paintFolderGlyph(Canvas canvas, Rect cell, double s, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final w = s * 0.9;
    final h = s * 0.72;
    // Position the glyph just left of the path, vertically centered on the row.
    final left = cell.left - w - 2.0;
    if (left < 0) return; // no room at the screen edge — skip the glyph
    final top = cell.top + (cell.height - h) / 2;
    final tabW = w * 0.45;
    final tabH = h * 0.22;
    final path = Path()
      ..moveTo(left, top + tabH)
      ..lineTo(left, top + h)
      ..lineTo(left + w, top + h)
      ..lineTo(left + w, top + tabH)
      ..lineTo(left + tabW, top + tabH)
      ..lineTo(left + tabW - tabH, top)
      ..lineTo(left + tabH, top)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PathPainter old) {
    if (identical(old.anchors, anchors)) return false;
    if (old.anchors.length != anchors.length) return true;
    for (var i = 0; i < anchors.length; i++) {
      final a = anchors[i];
      final b = old.anchors[i];
      if (a.color != b.color || a.payload != b.payload) return true;
      if (a.rects.length != b.rects.length) return true;
      for (var j = 0; j < a.rects.length; j++) {
        if (a.rects[j] != b.rects[j]) return true;
      }
    }
    return false;
  }
}

/// The overlay layer that resolves the controller's live anchors to viewport
/// rects and dispatches each to its registered decorator (#767 Slice B).
///
/// Listens to the [controller] (a `ChangeNotifier` that fires on output writes,
/// scroll, resize, …) so the decorators re-resolve + repaint as the viewport
/// moves — tracking scroll/wrap/resize/eviction with NO re-detection (the fork
/// re-anchors; this layer just re-reads the live geometry). Sits in the view's
/// `Stack` above the `TerminalView`, below the gesture/affordance layers.
class GhosttyTerminalDecoratorLayer extends StatelessWidget {
  const GhosttyTerminalDecoratorLayer({
    super.key,
    required this.controller,
    required this.registry,
    required this.color,
  });

  /// The SAME controller handed to the flterm `TerminalView`. Its `anchors` /
  /// `anchorRects` drive the decorators; its notifications drive repaint.
  final TerminalController controller;

  /// Pattern-id → decorator map.
  final GhosttyDecoratorRegistry registry;

  /// The theme accent color the decorators paint in (the session selection
  /// color). Rebuilds when the parent re-creates the layer with a new color.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Group each anchor's live rects under its decorator. Resolved fresh
        // every build from the current viewport offset/metrics.
        final byDecorator = <GhosttyTerminalDecorator, List<GhosttyDecoratedAnchor>>{};
        for (final anchor in controller.anchors) {
          final decorator = registry.forPattern(anchor.patternId);
          if (decorator == null) continue;
          final rects = <Rect>[];
          for (final range in anchor.ranges) {
            rects.addAll(controller.anchorRects(range));
          }
          if (rects.isEmpty) continue; // fully off-screen
          byDecorator.putIfAbsent(decorator, () => []).add(
                GhosttyDecoratedAnchor(
                  payload: anchor.payload,
                  rects: rects,
                  color: color,
                ),
              );
        }
        if (byDecorator.isEmpty) return const SizedBox.shrink();
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final entry in byDecorator.entries)
              entry.key.build(context, entry.value),
          ],
        );
      },
    );
  }
}
