// ghostty_terminal_decorators.dart — structured-text pattern ids, the LIVE wash
// LAYER, and shared wash-colour derivation for the forked flterm terminal.
//
// #955 retired the original inline bubble (scroll drift, the #930 + #803/#812/
// #863/#864 saga); #985 removed the drift class at the root; #988 restored the
// bubble as a widget-layer overlay on the stable geometry; #1000 re-skinned it
// as a translucent WASH; #1045 moved that wash INTO the fork's HighlightPainter
// (behind the glyphs) so the text stayed full-contrast. But the render-box wash
// only redrew when the render box repainted, so on a continuously-repainting TUI
// the device saw a FROZEN / stale band while the gutter chip (a widget layer)
// tracked fine (#1074 device reports: lastSyncRebuiltRows=0 + forceRepaints).
//
// #1074 takes the wash back OUT of the paint cycle: it is a LIVE widget LAYER
// ([GhosttyWashLayer]) painted UNDERNEATH a TRANSPARENT-background terminal
// (backgroundOpacity 0). Stack bottom→top: solid backdrop (theme.background) →
// this wash layer (capsule fills resolved LIVE from the controller's anchor set
// EVERY build, on the narrow decoration listenable — the SAME live resolution
// the gutter chip uses) → the terminal (default-bg cells transparent so the
// wash shows through BEHIND the glyphs; explicit-bg cells + glyphs opaque on
// top). This is the #1000 GhosttyBubbleLayer restored as the wash layer — its
// only flaw was DIMMING (it painted OVER the glyphs); UNDER a transparent
// terminal that flaw is gone. Rebuilding live from the current anchor set each
// build makes tracking (scroll AND in-place repaint), eviction within a frame,
// and non-accumulation INHERENT (there is no baked/cached wash state). The
// capsule GEOMETRY (#988/#1000 content-hugging, rounded caps only on the true
// first/last on-screen rows) is the fork's `highlightCapsuleRRect`, reused here
// so the widget-layer wash is pixel-identical to the retired render-box fill.
// The per-anchor gating (verified alpha #990, #995 exceptions, relpath hiding
// #1036, Detection Lab live-apply #1031) is composed by [ghosttyWashCapsuleColor]
// over the app's live washColorOf. The right-edge gutter marks
// (`ghostty_gutter_layer.dart`) are unchanged.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../storage/custom_patterns_store.dart' show isCustomPatternId;

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

/// The id of the RELATIVE FILE PATH pattern (#1036) — the fork's
/// `TextPattern.relativePath` over bare `a/b` tokens. Distinct from
/// [kGhosttyPathPatternId] so gating can treat it separately: a relpath anchor
/// is INVISIBLE until its cwd-resolved absolute path passes the #990 SFTP-stat
/// verification (there is no "detected but unverified" visible state for this
/// class — shape-level recall is deliberately broad, the verifier is the
/// precision gate).
const String kGhosttyRelPathPatternId = 'relpath';

/// The id of the COMMAND-LINE pattern (#998 slice C) — the fork's BLOCK-tier
/// `TextPattern.command` over a whole prompt-anchored command line, for
/// copy-to-paste. Matches the factory's default id. Deliberately excluded from
/// [ghosttyPatternPaintsWash]: the command block's affordance is GUTTER-ONLY
/// (an Icons.terminal chip); its inner url/path/osc8 span anchors keep their
/// own washes and taps inside it.
const String kGhosttyCommandPatternId = 'command';

/// #864/#1045/#1074: the style detection patterns REGISTER with — deliberately
/// empty. The wash is painted by the LIVE widget layer ([GhosttyWashLayer]),
/// resolved per ANCHOR from [ghosttyWashCapsuleColor], never baked into the
/// registration: a static per-pattern style could not express the #990 verified
/// alpha, the #995 exception suppression, or a Detection Lab live re-tune. With
/// an empty registration style the fork's HighlightPainter fills NOTHING for
/// detection (the #1074 relocation stopped installing an app
/// `detectionHighlightStyleOf` resolver), so the glyphs stay completely
/// untouched by the render box. A genuine SGR-4 underline emitted by the remote
/// is the shell's own ink and is unaffected — this only governs the APP's
/// structured-text decoration.
const HighlightStyle kGhosttyUrlHighlightStyle =
    HighlightStyle(background: null, underline: null);

/// Whether [patternId]'s anchors paint the inline background WASH. URL, OSC-8
/// and both path classes share the ONE mechanism (#988); every USER-DEFINED
/// `custom.*` pattern gets the same inline affordance (#1031 slice 3). The
/// command BLOCK pattern stays gutter-only (#998 C).
bool ghosttyPatternPaintsWash(String patternId) =>
    patternId == kGhosttyUrlPatternId ||
    patternId == kGhosttyOsc8PatternId ||
    patternId == kGhosttyPathPatternId ||
    // #1036: relative paths share the path wash; the visibility gate keeps
    // them invisible until their cwd-resolved absolute verifies.
    patternId == kGhosttyRelPathPatternId ||
    isCustomPatternId(patternId);

/// #1074: the pure gate for the LIVE wash LAYER — the capsule FILL colour one
/// detected anchor's wash paints in, or null when it paints NOTHING (a non-wash
/// pattern, or a #990/#995 suppressed anchor). Composes EXACTLY the gates the
/// retired #1045 render-box resolver did — [ghosttyPatternPaintsWash] (the
/// command BLOCK pattern stays gutter-only) and the #990/#995/#1036 visibility
/// suppression — but returns the bare [Color] the widget layer fills a
/// [highlightCapsuleRRect] with (UNDER the transparent terminal), not a fork
/// `HighlightStyle`. [washColorOf] is the #1031 style-resolver seam (stored
/// override composed over the shipped #1000 derivation, verified-shade aware).
Color? ghosttyWashCapsuleColor({
  required String patternId,
  required bool visible,
  required bool verified,
  required Color Function(String patternId, {required bool verified})
  washColorOf,
}) {
  if (!ghosttyPatternPaintsWash(patternId)) return null;
  // #990 visibility gate: suppressed anchors paint nothing at all.
  if (!visible) return null;
  return washColorOf(patternId, verified: verified);
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

/// #1000 wash alphas — the wash is a translucent background FILL (no stroke),
/// tuned per terminal-BACKGROUND luminance. Since #1045 the glyphs paint OVER
/// the wash (full brightness by construction), so the fill composites UNDER the
/// text over the near-black terminal cell background. #1053 re-tuned these UP
/// from the old over-glyphs regime; #1060 (owner P0 on +138) dials them back
/// DOWN: at 0.55 detected the wash read as "much too intense" — it dominated the
/// text it was meant to annotate. The target is "clearly visible but SECONDARY":
/// between the invisible +136 (0.26) and the overpowering +138 (0.55). Detected
/// stays a quiet clear-but-secondary fill; verified is clearly stronger
/// (detected < verified by a visible margin). The Detection Lab intensity band
/// still multiplies these via `resolveStyle`, clamped to [0,1].
const double kGhosttyBubbleDetectedWashAlphaOnDark = 0.35;

/// Detected wash alpha over a LIGHT terminal background (#1000, re-tuned #1060).
const double kGhosttyBubbleDetectedWashAlphaOnLight = 0.30;

/// VERIFIED wash alpha over a dark terminal background (#990 shade, #1000
/// wash language, re-tuned #1060): a detected file path confirmed to exist on
/// the host.
const double kGhosttyBubbleVerifiedWashAlphaOnDark = 0.55;

/// Verified wash alpha over a LIGHT terminal background (#1000, re-tuned #1060).
const double kGhosttyBubbleVerifiedWashAlphaOnLight = 0.45;

/// The wash colour (#1000): the SAME opaque hue as the gutter chip —
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

/// One anchor's resolved wash (#1074): its on-screen capsule [rects] (degenerate
/// rects dropped) and the fill [color]. Capsules round their caps ONLY on the
/// anchor's true first/last on-screen rect (a wrap-continuation edge is cut
/// square) so a wrapped match reads as ONE object flowing through the wrap — the
/// #988/#1000 geometry, via [highlightCapsuleRRect]. Immutable + value-equal so
/// the painter's [CustomPainter.shouldRepaint] and the live-tracking test can
/// compare the wash set frame-to-frame.
@immutable
class GhosttyAnchorWash {
  const GhosttyAnchorWash({required this.rects, required this.color});

  /// The anchor's on-screen per-row cell-range rects, top-to-bottom, already
  /// filtered to non-degenerate rects.
  final List<Rect> rects;

  /// The wash fill colour ([ghosttyWashCapsuleColor] output).
  final Color color;

  /// Build from an anchor's raw on-screen [rects] (from `anchorRects`), dropping
  /// degenerate ones. Null when nothing paints (every rect off-screen /
  /// degenerate) so the caller omits a fully off-screen anchor.
  static GhosttyAnchorWash? fromRects(List<Rect> rects, Color color) {
    final valid = <Rect>[
      for (final r in rects)
        if (r.width > 0 && r.height > 0) r,
    ];
    if (valid.isEmpty) return null;
    return GhosttyAnchorWash(rects: valid, color: color);
  }

  /// The capsule RRects to FILL — [highlightCapsuleRRect] per rect, rounded caps
  /// ONLY on the first/last on-screen rect.
  List<RRect> capsules() => [
        for (var i = 0; i < rects.length; i++)
          highlightCapsuleRRect(
            rects[i],
            roundLeft: i == 0,
            roundRight: i == rects.length - 1,
          ),
      ];

  @override
  int get hashCode => Object.hash(color, Object.hashAll(rects));

  @override
  bool operator ==(Object other) =>
      other is GhosttyAnchorWash &&
      other.color == color &&
      listEquals(other.rects, rects);
}

/// Resolve the LIVE wash set (#1074) from the CURRENT [anchors] — one
/// [GhosttyAnchorWash] per anchor that paints a wash, its on-screen capsule
/// rects from [rectsOf] (production: `TerminalController.anchorRects`) and its
/// fill from [washColorFor] (null → paints nothing: non-wash pattern or #990/
/// #995 suppressed).
///
/// A PURE function of the live anchor set: nothing is baked or accumulated, so
/// the returned washes are EXACTLY today's visible wash-painting anchors.
/// Tracking (the anchor's rects move with the painted offset each build),
/// eviction (an anchor dropped from [anchors], or whose rects all go off-screen,
/// vanishes on the very next call), and non-accumulation (calling twice yields
/// the same set, never a union with a prior frame) are therefore inherent —
/// asserted headless in the #1074 live-tracking test.
List<GhosttyAnchorWash> ghosttyResolveWashes(
  Iterable<StructuredAnchor> anchors, {
  required List<Rect> Function(HighlightRange range) rectsOf,
  required Color? Function(StructuredAnchor anchor) washColorFor,
}) {
  final washes = <GhosttyAnchorWash>[];
  for (final anchor in anchors) {
    final color = washColorFor(anchor);
    if (color == null) continue; // non-wash pattern or suppressed
    final rects = <Rect>[];
    for (final range in anchor.ranges) {
      rects.addAll(rectsOf(range));
    }
    final wash = GhosttyAnchorWash.fromRects(rects, color);
    if (wash == null) continue; // fully off-screen / degenerate
    washes.add(wash);
  }
  return washes;
}

/// The LIVE wash LAYER (#1074) — a paint-only overlay drawing one translucent
/// capsule wash per detected URL / OSC-8 link / file path, mounted UNDERNEATH
/// the transparent-background terminal so the glyphs stay full-contrast ON TOP
/// (the DIMMING flaw of the retired #988/#1000 over-glyphs bubble is gone).
///
/// This is the #1000 GhosttyBubbleLayer restored as the wash layer. Geometry
/// comes from `controller.anchorRects` per per-row range — the post-#985
/// painted-offset resolver, the SAME source `matchAt` hit-tests and the gutter
/// chip use — so the wash cannot diverge from the painted glyphs. It rebuilds
/// the FULL wash set from the controller's CURRENT [TerminalController.anchors]
/// EVERY build on the narrow [TerminalController.decorationListenable] (fires
/// post-frame on every anchor-set / painted-offset change), optionally merged
/// with [repaintListenable] (#990 the path verifier, so a verification result
/// recolours / evicts the wash with no anchor change).
///
/// Unlike the #988 bubble it does NOT hide while scrolling: the wash tracks its
/// token mid-scroll exactly as the gutter chip does (#993), because every
/// painted-offset notify re-resolves `anchorRects` against that same painted
/// offset. [IgnorePointer]: taps fall through to the gesture router below (the
/// `matchAt` hit-test, never this fill, routes a tap).
class GhosttyWashLayer extends StatelessWidget {
  const GhosttyWashLayer({
    super.key,
    required this.controller,
    required this.washColorFor,
    this.repaintListenable,
  });

  /// The SAME controller handed to the flterm `TerminalView`. Its `anchors` /
  /// `anchorRects` drive the washes; its notifications drive repaint.
  final TerminalController controller;

  /// Resolves one anchor's wash FILL colour, or null when it paints nothing.
  /// The view supplies a closure over [ghosttyWashCapsuleColor] + its live
  /// visibility / verification gates + the #1031 style resolver, so the colour
  /// tracks theme / lab / exception changes (the parent rebuilds this layer) and
  /// verification (the [repaintListenable] rebuilds it in place).
  final Color? Function(StructuredAnchor anchor) washColorFor;

  /// #990: merged with the decoration listenable so a verification result (no
  /// anchor change) repaints the wash. Null → repaint on decoration only.
  final Listenable? repaintListenable;

  @override
  Widget build(BuildContext context) {
    final repaint = repaintListenable;
    return ListenableBuilder(
      listenable: repaint == null
          ? controller.decorationListenable
          : Listenable.merge([controller.decorationListenable, repaint]),
      builder: (context, _) {
        final washes = ghosttyResolveWashes(
          controller.anchors,
          rectsOf: controller.anchorRects,
          washColorFor: washColorFor,
        );
        if (washes.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            key: const Key('ghostty-wash-paint'),
            painter: _GhosttyWashPainter(washes: washes),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

/// Fills each anchor's wash capsules with its colour. A FILL (never a stroke) so
/// the wash reads as a solid translucent chip UNDER the glyphs; the transparent
/// terminal above lets it show through default-bg cells and occludes it on
/// explicit-bg cells / glyphs.
class _GhosttyWashPainter extends CustomPainter {
  _GhosttyWashPainter({required this.washes});

  final List<GhosttyAnchorWash> washes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final wash in washes) {
      paint.color = wash.color;
      for (final rrect in wash.capsules()) {
        canvas.drawRRect(rrect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GhosttyWashPainter old) =>
      !listEquals(old.washes, washes);
}
