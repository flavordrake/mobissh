// ghostty_terminal_decorators.dart — structured-text pattern ids, the wash
// styling seam, and shared wash-colour derivation for the forked flterm
// terminal.
//
// #955 retired the original inline bubble (scroll drift, the #930 + #803/#812/
// #863/#864 saga); #985 removed the drift class at the root; #988 restored the
// bubble as a widget-layer overlay on the stable geometry; #1000 re-skinned it
// as a translucent WASH. #1045 moves the wash INTO the fork's own paint order:
// a widget-layer overlay necessarily paints ABOVE the canvas and DIMS the
// glyphs, while the fork's HighlightPainter fills render between the cell
// background and the glyph ink — background → highlight fills → glyphs — so
// the text stays full-contrast ON TOP of the wash. The per-anchor styling
// (verified alpha #990, #995 exceptions, relpath hiding #1036, Detection Lab
// live-apply #1031) routes through the controller's `detectionHighlightStyleOf`
// resolver seam; [ghosttyWashHighlightStyle] here is that resolver's pure
// core. The capsule GEOMETRY (#988/#1000 content-hugging per-row segments,
// rounded caps only on the true first/last rows) lives in the fork
// (`highlightCapsuleRRect`) behind the HighlightStyle.capsule flag.
//
// A side effect that is a strict UX improvement: the wash is now painted from
// the SAME frame snapshot as the glyphs, so it scrolls WITH the grid — the
// old hide-while-scrolling special-casing (#812) is gone with the overlay.
// The right-edge gutter marks (`ghostty_gutter_layer.dart`) are unchanged.

import 'package:flterm/flterm.dart' hide Key;
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

/// #864/#1045: the style detection patterns REGISTER with — deliberately empty.
/// The wash is resolved per ANCHOR through the controller's
/// `detectionHighlightStyleOf` seam ([ghosttyWashHighlightStyle]), never baked
/// into the registration: a static per-pattern style could not express the
/// #990 verified alpha, the #995 exception suppression, or a Detection Lab
/// live re-tune. With no resolver installed this empty style leaves the glyphs
/// completely untouched (the fork only fills when a range opts in). A genuine
/// SGR-4 underline emitted by the remote is the shell's own ink and is
/// unaffected — this only governs the APP's structured-text decoration.
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

/// #1045: the pure core of the app's `detectionHighlightStyleOf` resolver —
/// the [HighlightStyle] one detected match paints its behind-glyph wash with,
/// or null when it paints NOTHING (a non-wash pattern, or a #990/#995
/// suppressed anchor). [washColorOf] is the #1031 style-resolver seam
/// (stored override composed over the shipped #1000 derivation); capsule is
/// always on — the wash IS the capsule look, now drawn by the fork's
/// HighlightPainter under the glyphs.
HighlightStyle? ghosttyWashHighlightStyle({
  required String patternId,
  required bool visible,
  required bool verified,
  required Color Function(String patternId, {required bool verified})
  washColorOf,
}) {
  if (!ghosttyPatternPaintsWash(patternId)) return null;
  // #990 visibility gate: suppressed anchors paint nothing at all.
  if (!visible) return null;
  return HighlightStyle(
    background: washColorOf(patternId, verified: verified),
    capsule: true,
  );
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
