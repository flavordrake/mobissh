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
// it visibly respects line wraps and omits injected margin whitespace, so the
// bubble IS the preview of what a single tap will copy. #1000 re-skins it as a
// translucent background WASH (no outline — the stroke crowded neighbors) in
// the gutter chip's hue at a luminance-tuned alpha. The right-edge gutter
// marks (`ghostty_gutter_layer.dart`) coexist unchanged.
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

/// The id of the COMMAND-LINE pattern (#998 slice C) — the fork's BLOCK-tier
/// `TextPattern.command` over a whole prompt-anchored command line, for
/// copy-to-paste. Matches the factory's default id. Deliberately ABSENT from
/// [GhosttyBubbleLayer._bubblePatternIds]: the command block's affordance is
/// GUTTER-ONLY (an Icons.terminal chip); its inner url/path/osc8 span anchors
/// keep their own bubbles and taps inside it.
const String kGhosttyCommandPatternId = 'command';

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

  /// The rounded rect to fill: capsule radius (half the segment height) on
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

/// TOP inset: flterm's cell rect spans the full typographic line height with
/// its empty slack band at the TOP (#864), so the wash trims most of that band
/// — but keeps a hair of it as breathing room above the glyph caps (#1000).
const double _kBubbleTopInset = 2.0;

/// BOTTOM outset (#1000): the glyph ink (descenders) runs close to the cell
/// rect's bottom, so the wash EXPANDS downward past it — the #988 outline sat
/// only 0.5px below and read cramped under descenders. The next row's top
/// slack band (see [_kBubbleTopInset]) absorbs the overhang, so neighbors stay
/// uncrowded.
const double _kBubbleBottomOutset = 2.0;

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
      rect.top + _kBubbleTopInset,
      rect.right + _kBubblePadX,
      rect.bottom + _kBubbleBottomOutset,
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

/// #1000 wash alphas — the bubble is a translucent background FILL (no
/// stroke), tuned per terminal-BACKGROUND luminance: a dark terminal needs
/// less pigment for the wash to register than a light one (where ambient
/// screen brightness washes out faint tints). Detected < verified by a
/// clearly-visible margin at phone density, and every value stays inside the
/// readable band (glyphs legible in the wash; the wash still distinct from
/// flterm's ~0x33-alpha native selection fill).
const double kGhosttyBubbleDetectedWashAlphaOnDark = 0.26;

/// Detected wash alpha over a LIGHT terminal background (#1000).
const double kGhosttyBubbleDetectedWashAlphaOnLight = 0.32;

/// VERIFIED wash alpha over a dark terminal background (#990 shade, #1000
/// wash language): a detected file path confirmed to exist on the host.
const double kGhosttyBubbleVerifiedWashAlphaOnDark = 0.42;

/// Verified wash alpha over a LIGHT terminal background (#1000).
const double kGhosttyBubbleVerifiedWashAlphaOnLight = 0.50;

/// The bubble wash colour (#1000): the SAME opaque hue as the gutter chip —
/// `GutterMarkStyle.chipColor` forces the accent's alpha to 1.0, mirrored here
/// (the gutter file imports this one, so the derivation lives here and the
/// chip's is kept in sync by the shared-hue widget test) — at the
/// luminance-tuned wash alpha. One hue family for the whole detection
/// affordance: chip green → pale green wash.
Color ghosttyBubbleWashColor(
  Color accent, {
  required bool verified,
  required Brightness backgroundBrightness,
}) {
  final dark = backgroundBrightness == Brightness.dark;
  final alpha = verified
      ? (dark
            ? kGhosttyBubbleVerifiedWashAlphaOnDark
            : kGhosttyBubbleVerifiedWashAlphaOnLight)
      : (dark
            ? kGhosttyBubbleDetectedWashAlphaOnDark
            : kGhosttyBubbleDetectedWashAlphaOnLight);
  return accent.withValues(alpha: alpha);
}

/// One anchor's renderable bubble (#990): its per-row [segments] plus whether
/// it renders in the bolder VERIFIED shade. Public (with the painter) so the
/// widget test can assert shade selection without reaching into paint calls.
@immutable
class GhosttyBubbleSpec {
  const GhosttyBubbleSpec({
    required this.segments,
    required this.verified,
    this.washColor,
  });

  final List<GhosttyBubbleSegment> segments;
  final bool verified;

  /// #1031: the RESOLVED per-pattern wash fill (from the detection style
  /// resolver seam). Null → the painter derives the shipped default from its
  /// accent + brightness, exactly as before the seam existed.
  final Color? washColor;
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
    required this.backgroundBrightness,
    this.isVerified,
    this.isVisible,
    this.verificationListenable,
    this.washColorOf,
  });

  /// The SAME controller handed to the flterm `TerminalView`. Its `anchors` /
  /// `anchorRects` drive the bubbles; its notifications drive repaint.
  final TerminalController controller;

  /// The theme accent the wash is tinted in (the session selection colour —
  /// the gutter chip's hue family, #1000). Rebuilds when the parent re-creates
  /// the layer with a new colour.
  final Color color;

  /// The TERMINAL background's luminance (#1000): the wash alpha is tuned per
  /// theme brightness ([ghosttyBubbleWashColor]), not one fixed constant.
  final Brightness backgroundBrightness;

  /// #990: OPAQUE verification predicate — true renders the anchor's bubble in
  /// the bolder VERIFIED shade (the stronger-alpha wash, #1000). Null → every
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

  /// #1031: the detection style RESOLVER seam — maps (patternId, state) to the
  /// effective wash fill (stored override composed over the shipped #1000
  /// derivation). Null → the pre-#1031 default derivation from [color] +
  /// [backgroundBrightness]; the production view always passes the
  /// resolver-backed function, whose EMPTY-store output is bit-identical to
  /// that default (zero visual change).
  final Color Function(String patternId, {required bool verified})?
  washColorOf;

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
          final verified = isVerified?.call(anchor) ?? false;
          specs.add(
            GhosttyBubbleSpec(
              segments: segments,
              verified: verified,
              // #1031: resolve the per-pattern wash HERE (on decoration
              // change), so the painter stays a dumb fill — no per-frame
              // resolver reads.
              washColor: washColorOf?.call(
                anchor.patternId,
                verified: verified,
              ),
            ),
          );
        }
        if (specs.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            key: const Key('ghostty-bubble-paint'),
            painter: GhosttyBubblePainter(
              specs: specs,
              color: color,
              backgroundBrightness: backgroundBrightness,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

/// Fills one translucent background WASH per bubble segment (#1000) — never a
/// stroke: the #988 outline visually crowded the lines above/below and the
/// characters just outside the capsule, while a low-alpha fill stays inside
/// the glyph rows. The wash colour is the gutter chip's hue at a
/// luminance-tuned alpha ([ghosttyBubbleWashColor]); a VERIFIED spec (#990)
/// fills the SAME hue at a clearly stronger alpha. Public (with final fields)
/// so the widget test can assert the detected/verified shade selection.
class GhosttyBubblePainter extends CustomPainter {
  GhosttyBubblePainter({
    required this.specs,
    required this.color,
    required this.backgroundBrightness,
  });

  final List<GhosttyBubbleSpec> specs;
  final Color color;
  final Brightness backgroundBrightness;

  /// The fill a spec paints in: its RESOLVED wash (#1031 seam) when present,
  /// else the shipped derivation from the accent + brightness. Public so
  /// tests assert the painted color without recording canvas calls.
  Color effectiveWashColor(GhosttyBubbleSpec spec) =>
      spec.washColor ??
      ghosttyBubbleWashColor(
        color,
        verified: spec.verified,
        backgroundBrightness: backgroundBrightness,
      );

  @override
  void paint(Canvas canvas, Size size) {
    // One Paint per distinct wash color (typically 1–2: detected + verified).
    final paints = <Color, Paint>{};
    for (final spec in specs) {
      final wash = effectiveWashColor(spec);
      final paint = paints[wash] ??= (Paint()
        ..style = PaintingStyle.fill
        ..color = wash
        ..isAntiAlias = true);
      for (final segment in spec.segments) {
        canvas.drawRRect(segment.toRRect(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant GhosttyBubblePainter old) {
    if (old.color != color) return true;
    if (old.backgroundBrightness != backgroundBrightness) return true;
    if (old.specs.length != specs.length) return true;
    for (var i = 0; i < specs.length; i++) {
      final a = specs[i];
      final b = old.specs[i];
      if (a.verified != b.verified) return true;
      if (a.washColor != b.washColor) return true;
      if (a.segments.length != b.segments.length) return true;
      for (var j = 0; j < a.segments.length; j++) {
        if (a.segments[j] != b.segments[j]) return true;
      }
    }
    return false;
  }
}
