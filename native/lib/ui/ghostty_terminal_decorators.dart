// ghostty_terminal_decorators.dart — structured-text pattern ids + highlight
// style for the forked flterm terminal.
//
// #955 PIVOT: the INLINE per-glyph decorations that used to live here (the URL
// bubble / path underline painters + the `GhosttyTerminalDecoratorLayer` that
// resolved anchor rects every frame) were RETIRED. They had to hug the matched
// glyph cells to sub-pixel precision each frame, so they drifted off their text
// during scroll (the still-open #930 + the #803/#812/#863/#864 saga). They are
// replaced by `ghostty_gutter_layer.dart`'s `GhosttyGutterLayer`: a right-edge
// gutter mark needs only a ROW + a fixed edge X, so the whole drift class is
// gone (no text under the mark to drift away from).
//
// What REMAINS here is the small shared contract both the controller's pattern
// registration and the gutter layer key off: the pattern ids and the (empty)
// URL highlight style.

import 'package:flterm/flterm.dart';

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
/// background fill, no underline). With the inline bubble retired (#955) the URL
/// affordance is the GUTTER mark; the fork's `HighlightPainter` only draws a
/// fill/underline when a range's style opts in, so a null-on-both style leaves
/// the glyphs completely untouched (no app-painted ink over the URL text). A
/// genuine SGR-4 underline emitted by the remote is the shell's own ink and is
/// unaffected — this only governs the APP's structured-text decoration.
const HighlightStyle kGhosttyUrlHighlightStyle =
    HighlightStyle(background: null, underline: null);
