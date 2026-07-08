// ghostty_terminal_decorators.dart — structured-text pattern ids, highlight
// style, and the INLINE BUBBLE decorator for the forked flterm terminal.
//
// #955 retired the original inline bubble: it drifted off its glyphs during
// scroll (the #930 + #803/#812/#863/#864 saga) because the geometry it resolved
// could disagree with the painted frame. #985 removed that drift class at the
// ROOT — the controller runs NO damage-consuming RenderState reads and
// `anchorRects` resolves per-row rects purely from the resize-seam grid cache +
// the PAINTED viewport offset, the SAME source `matchAt` hit-tests with (#863).
// #988 restores the bubble on that stable geometry as the primary affordance:
// a rounded outline that visibly respects line wraps and omits injected margin
// whitespace, so the bubble IS the preview of what a single tap will copy. The
// right-edge gutter marks (`ghostty_gutter_layer.dart`) coexist unchanged.
//
// This file keeps the shared contract (pattern ids + the EMPTY highlight style
// — the bubble is a WIDGET-layer decorator per the #767 Slice B design, never a
// per-glyph fill) and adds the restored bubble: the pure per-row segment
// computation ([ghosttyBubbleSegments]) and the paint-only [GhosttyBubbleLayer].

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/widgets.dart';

/// The id of the built-in URL pattern. Mirrors the pattern id the view registers
/// on the controller so the gutter registry can route URL anchors to their mark.
const String kGhosttyUrlPatternId = 'url';

/// The id of the OSC-8 HYPERLINK pattern. The PRIMARY, exact URL source: the
/// terminal reads the OSC-8 URI off its own cells (no regex), so a wrapped link
/// spans all its rows and the payload is the exact full URI. Its gutter mark is
/// the SAME affordance as a regex URL.
const String kGhosttyOsc8PatternId = 'osc8';

/// The id of the absolute FILE PATH pattern (#778, paths Slice 1). Mirrors the
/// pattern id the view registers so the gutter registry routes path anchors to
/// the path mark (a distinct glyph + action set from the URL).
const String kGhosttyPathPatternId = 'path';

/// #864: the URL/OSC-8 pattern highlight style — DELIBERATELY EMPTY (no
/// background fill, no underline). The bubble is a WIDGET-layer decorator
/// ([GhosttyBubbleLayer], #767 Slice B / #988) — never a per-glyph fill; the
/// fork's `HighlightPainter` only draws a fill/underline when a range's style
/// opts in, so a null-on-both style leaves the glyphs completely untouched (no
/// app-painted ink over the URL text). A genuine SGR-4 underline emitted by the
/// remote is the shell's own ink and is unaffected — this only governs the
/// APP's structured-text decoration.
const HighlightStyle kGhosttyUrlHighlightStyle =
    HighlightStyle(background: null, underline: null);

/// One per-row piece of a (possibly wrapped) bubble (#988).
///
/// [rect] is the DRAW rect (the row's cell rect padded/inset by
/// [ghosttyBubbleSegments]); [roundLeft]/[roundRight] mark the capsule ends —
/// rounded ONLY where the anchor actually starts/ends, so a wrapped match reads
/// as ONE object flowing through the wrap: the first row's segment rounds its
/// left end, the last row's segment rounds its right end, middle rows are cut
/// square on both ends (the wrap continues), and a single-row match is a full
/// capsule.
@immutable
class GhosttyBubbleSegment {
  const GhosttyBubbleSegment({
    required this.rect,
    required this.roundLeft,
    required this.roundRight,
  });

  final Rect rect;
  final bool roundLeft;
  final bool roundRight;

  /// The rounded rect to stroke: capsule radius (half the segment height) on
  /// the rounded end(s), square corners on a cut (wrap-continuation) end.
  RRect toRRect() {
    final radius = Radius.circular(rect.height / 2);
    return RRect.fromRectAndCorners(
      rect,
      topLeft: roundLeft ? radius : Radius.zero,
      bottomLeft: roundLeft ? radius : Radius.zero,
      topRight: roundRight ? radius : Radius.zero,
      bottomRight: roundRight ? radius : Radius.zero,
    );
  }

  @override
  int get hashCode => Object.hash(rect, roundLeft, roundRight);

  @override
  bool operator ==(Object other) =>
      other is GhosttyBubbleSegment &&
      other.rect == rect &&
      other.roundLeft == roundLeft &&
      other.roundRight == roundRight;
}

/// HORIZONTAL padding on both sides so the capsule FRAMES the text with a
/// little breathing room instead of clipping the first/last glyph (#864 device
/// feedback, carried over from the retired bubble's polish).
const double _kBubblePadX = 3.0;

/// VERTICAL inset: flterm's cell rect spans the full typographic line height
/// (ascender + descender slack), so an uninset outline sits top-heavy over the
/// glyphs (#864). Insetting shrinks that slack.
const double _kBubblePadY = 1.0;

/// DOWNWARD shift: after insetting, nudge the outline down so it is vertically
/// CENTERED on the glyph ink (the cell's empty band is at the TOP, #864).
const double _kBubbleShiftY = 1.5;

/// Compute the per-row bubble segments for an anchor's on-screen row rects
/// (#988). Pure and headless-testable.
///
/// [rowRects] are the anchor's per-row viewport rects in top-to-bottom order —
/// one per visible wrapped row, ALREADY content-hugging: the scanner's per-row
/// ranges start at the match's start col on the first row and at the row's
/// CONTENT start on continuation rows (injected margin whitespace excluded,
/// #925/#928), and `TerminalController.anchorRects` resolves them against the
/// painted offset. Each rect becomes one padded segment; capsule ends land ONLY
/// on the first/last segments (see [GhosttyBubbleSegment]). Degenerate rects
/// are skipped. Empty when the anchor is fully off-screen.
List<GhosttyBubbleSegment> ghosttyBubbleSegments(List<Rect> rowRects) {
  final padded = <Rect>[];
  for (final rect in rowRects) {
    if (rect.width <= 0 || rect.height <= 0) continue;
    final bubble = Rect.fromLTRB(
      rect.left - _kBubblePadX,
      rect.top + _kBubblePadY + _kBubbleShiftY,
      rect.right + _kBubblePadX,
      rect.bottom - _kBubblePadY + _kBubbleShiftY,
    );
    if (bubble.width <= 0 || bubble.height <= 0) continue;
    padded.add(bubble);
  }
  return [
    for (var i = 0; i < padded.length; i++)
      GhosttyBubbleSegment(
        rect: padded[i],
        roundLeft: i == 0,
        roundRight: i == padded.length - 1,
      ),
  ];
}

/// #990 visibility gate: whether a detected path payload is a LOW-CONFIDENCE
/// match that must be VERIFIED (SFTP stat confirms existence) before ANY
/// affordance shows. True for SINGLE-SEGMENT root-level matches (`/config`,
/// `/rc` — no second slash): in terminal output those are overwhelmingly TUI
/// slash-commands (the +121 owner report), not paths. Multi-segment paths
/// (`/etc/hosts`) return false — they show immediately at the detected shade.
/// Degenerate payloads (`/`, empty) are conservatively true (suppressed).
bool ghosttyPathRequiresVerification(String payload) {
  var p = payload;
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  if (p.length < 2 || !p.startsWith('/')) return true; // degenerate
  return !p.substring(1).contains('/');
}

/// Stroke width of the plain "detected" bubble outline, logical px.
const double kGhosttyBubbleStrokeWidth = 1.5;

/// Stroke width of the bolder VERIFIED bubble outline (#990) — a detected
/// file path confirmed to exist on the connected host.
const double kGhosttyBubbleVerifiedStrokeWidth = 2.5;

/// Fill-wash alpha inside a VERIFIED bubble (#990). A faint tint (the text
/// stays fully readable) that, with the thicker stroke, makes the verified
/// shade legible at phone density.
const double kGhosttyBubbleVerifiedFillAlpha = 0.15;

/// One anchor's renderable bubble (#990): its per-row [segments] plus whether
/// it renders in the bolder VERIFIED shade. Public (with the painter) so the
/// widget test can assert shade selection without reaching into paint calls.
@immutable
class GhosttyBubbleSpec {
  const GhosttyBubbleSpec({required this.segments, required this.verified});

  final List<GhosttyBubbleSegment> segments;
  final bool verified;
}

/// The restored inline bubble layer (#988) — a paint-only overlay drawing one
/// wrap-aware outline bubble per detected URL / OSC-8 link / file path.
///
/// Geometry: `controller.anchorRects` per per-row range — the post-#985
/// painted-offset resolver, the SAME source `matchAt` hit-tests with (#863), so
/// the painted bubble and the tappable region cannot diverge. Listens to the
/// controller's NARROW `decorationListenable` (#805: fires only when the anchor
/// set or the painted offset changes) and HIDES while `isScrolling` (#812
/// stance: mid-scroll the painted offset is in flight; hidden is acceptable,
/// a drifting bubble is not — it re-shows on settle at exact placement).
///
/// [IgnorePointer]: taps fall through to the gesture router below, whose
/// `matchAt` hit-test routes a tap anywhere on the bubble to the single-tap
/// copy (`_copyUrl`), so the bubble needs no gesture handling of its own.
/// Mounted in the terminal Stack above the router, below the gutter layers.
class GhosttyBubbleLayer extends StatelessWidget {
  const GhosttyBubbleLayer({
    super.key,
    required this.controller,
    required this.color,
    this.isVerified,
    this.isVisible,
    this.verificationListenable,
  });

  /// The SAME controller handed to the flterm `TerminalView`. Its `anchors` /
  /// `anchorRects` drive the bubbles; its notifications drive repaint.
  final TerminalController controller;

  /// The theme accent the bubbles are stroked in (the session selection
  /// colour). Rebuilds when the parent re-creates the layer with a new colour.
  final Color color;

  /// #990: OPAQUE verification predicate — true renders the anchor's bubble in
  /// the bolder VERIFIED shade (thicker stroke + faint fill). Null → every
  /// bubble stays the plain detected shade. The layer doesn't know WHY an
  /// anchor is verified (today: exists-on-host via the session's SFTP stat),
  /// so the predicate's meaning can change without paint rework.
  final bool Function(StructuredAnchor anchor)? isVerified;

  /// #990 visibility gate: OPAQUE suppression predicate — false means the
  /// anchor paints NO bubble at all (a low-confidence single-segment match
  /// awaiting verification, or confirmed missing). Null → everything paints.
  final bool Function(StructuredAnchor anchor)? isVisible;

  /// #990: fires when a verification result lands (no anchor change involved)
  /// so the bubbles repaint. Merged with the controller's decoration
  /// listenable.
  final Listenable? verificationListenable;

  /// The pattern ids that render a bubble. URL, OSC-8 and path share the ONE
  /// mechanism (#988); a per-pattern shade difference is a separate issue.
  static const Set<String> _bubblePatternIds = {
    kGhosttyUrlPatternId,
    kGhosttyOsc8PatternId,
    kGhosttyPathPatternId,
  };

  @override
  Widget build(BuildContext context) {
    final verification = verificationListenable;
    return ListenableBuilder(
      listenable: verification == null
          ? controller.decorationListenable
          : Listenable.merge([controller.decorationListenable, verification]),
      builder: (context, _) {
        if (controller.isScrolling) return const SizedBox.shrink();
        final specs = <GhosttyBubbleSpec>[];
        for (final anchor in controller.anchors) {
          if (!_bubblePatternIds.contains(anchor.patternId)) continue;
          // #990 visibility gate: suppressed anchors paint nothing.
          if (!(isVisible?.call(anchor) ?? true)) continue;
          final rects = <Rect>[];
          for (final range in anchor.ranges) {
            rects.addAll(controller.anchorRects(range));
          }
          final segments = ghosttyBubbleSegments(rects);
          if (segments.isEmpty) continue; // fully off-screen
          specs.add(
            GhosttyBubbleSpec(
              segments: segments,
              verified: isVerified?.call(anchor) ?? false,
            ),
          );
        }
        if (specs.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            key: const Key('ghostty-bubble-paint'),
            painter: GhosttyBubblePainter(specs: specs, color: color),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

/// Strokes one outline per bubble segment — an OUTLINE (never an opaque fill
/// over the glyphs) so the text stays readable and the capsule reads as a
/// physical chip around it. A VERIFIED spec (#990) strokes thicker and adds a
/// faint fill wash. Public (with final fields) so the widget test can assert
/// the detected/verified shade selection.
class GhosttyBubblePainter extends CustomPainter {
  GhosttyBubblePainter({required this.specs, required this.color});

  final List<GhosttyBubbleSpec> specs;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = kGhosttyBubbleStrokeWidth
      ..color = color
      ..isAntiAlias = true;
    final verifiedStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = kGhosttyBubbleVerifiedStrokeWidth
      ..color = color
      ..isAntiAlias = true;
    final verifiedFill = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: kGhosttyBubbleVerifiedFillAlpha)
      ..isAntiAlias = true;
    for (final spec in specs) {
      for (final segment in spec.segments) {
        final rrect = segment.toRRect();
        if (spec.verified) canvas.drawRRect(rrect, verifiedFill);
        canvas.drawRRect(rrect, spec.verified ? verifiedStroke : stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant GhosttyBubblePainter old) {
    if (old.color != color) return true;
    if (old.specs.length != specs.length) return true;
    for (var i = 0; i < specs.length; i++) {
      final a = specs[i];
      final b = old.specs[i];
      if (a.verified != b.verified) return true;
      if (a.segments.length != b.segments.length) return true;
      for (var j = 0; j < a.segments.length; j++) {
        if (a.segments[j] != b.segments[j]) return true;
      }
    }
    return false;
  }
}
