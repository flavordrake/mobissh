// Detection style RESOLVER (#1031 slice 1) — the single composition point
// both the runtime affordances (bubble wash, gutter chip) and the future
// Detection Lab preview read. Zero styling logic exists twice: the lab
// previews call the SAME resolver over the SAME stored overrides.
//
// Composition, per (patternId, state):
//   hue   = stored colorHex override, else the per-session accent
//           (`palette.theme.selection` — overrides are GLOBAL, the accent
//           stays per-session, per the #1031 IA review)
//   alpha = the #1000 luminance-tuned base wash alpha for the state
//           × the stored per-state intensity multiplier, clamped to the
//           legibility band ([kDetectionIntensityMin]..[kDetectionIntensityMax],
//           IA review change 6: every stored value stays visible)
//
// The gutter CHIP takes only the hue: `GutterMarkStyle.chipColor` forces it
// opaque (contrast rule), so intensity governs the wash alone.
//
// An EMPTY store reproduces today's shipped visuals EXACTLY (the golden
// equality asserted in detection_style_resolver_test.dart) — shipping this
// slice changes nothing on screen.

import 'package:flutter/widgets.dart';

import '../storage/detection_styles_store.dart';
import 'ghostty_terminal_decorators.dart';

/// Floor of the intensity band. A stored multiplier below this clamps up so a
/// tuned wash can never silently vanish (#1031 IA review change 6: no
/// invisible no-op zone for a low-vision user relying on the preview).
const double kDetectionIntensityMin = 0.25;

/// Ceiling of the intensity band — keeps glyphs legible inside the wash.
const double kDetectionIntensityMax = 1.75;

/// Whether [patternId] has a REAL active state at runtime today. Per #990 the
/// verified (active) rendering is wired for PATHS only; url/command gain a
/// pressed state in a later slice. The lab UI reads this so it never offers a
/// control that tunes a state with no runtime effect (#1031 IA review change
/// 1: no dead controls). Unknown / custom ids have no active state.
bool detectionPatternHasActiveState(String patternId) =>
    patternId == kGhosttyPathPatternId;

/// Parse a `#RRGGBB` (or bare `RRGGBB`) hex string to an opaque [Color].
/// Anything else — wrong length, non-hex digits, empty — returns null so a
/// corrupt stored hue falls back to the session accent instead of crashing
/// or painting garbage.
Color? detectionColorFromHex(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 6) return null;
  final rgb = int.tryParse(h, radix: 16);
  if (rgb == null) return null;
  return Color(0xFF000000 | rgb);
}

/// The effective style for one (pattern, state): what the painters fill with.
@immutable
class ResolvedDetectionStyle {
  const ResolvedDetectionStyle({
    required this.washColor,
    required this.chipAccent,
  });

  /// The bubble wash fill — hue at the composed translucent alpha.
  final Color washColor;

  /// The gutter chip's accent HUE. The chip stays opaque by design
  /// ([GutterMarkStyle.chipColor] forces alpha 1.0) and intensity never
  /// touches it — only a colorHex override changes it.
  final Color chipAccent;

  @override
  bool operator ==(Object other) =>
      other is ResolvedDetectionStyle &&
      other.washColor == washColor &&
      other.chipAccent == chipAccent;

  @override
  int get hashCode => Object.hash(washColor, chipAccent);
}

/// Composes stored overrides with the shipped defaults. Built per terminal
/// build from (provider styles, session accent, background brightness) — the
/// inputs only change on a settings/theme change, so the painters resolve on
/// change, never per frame.
@immutable
class DetectionStyleResolver {
  const DetectionStyleResolver({
    this.styles = DetectionStyles.empty,
    required this.accent,
    required this.backgroundBrightness,
  });

  /// The stored per-pattern overrides (empty = shipped defaults everywhere).
  final DetectionStyles styles;

  /// The per-session accent (`palette.theme.selection`) used when a pattern
  /// has no colorHex override.
  final Color accent;

  /// The TERMINAL background's luminance — the base wash alphas are tuned per
  /// theme brightness (#1000).
  final Brightness backgroundBrightness;

  /// The effective color + alpha for [patternId] in the given state.
  /// [verified] selects the ACTIVE (verified, #990) state; the runtime only
  /// passes true where that state actually exists (paths today — see
  /// [detectionPatternHasActiveState] for the UI-facing truth).
  ResolvedDetectionStyle resolveStyle(
    String patternId, {
    required bool verified,
  }) {
    final style = styles.of(patternId);
    final hue = detectionColorFromHex(style?.colorHex) ?? accent;
    final intensity = verified
        ? style?.activeIntensity
        : style?.inactiveIntensity;
    // The default path is BIT-IDENTICAL to the shipped derivation: no
    // multiply, no re-clamp — ghosttyBubbleWashColor as-is.
    final base = ghosttyBubbleWashColor(
      hue,
      verified: verified,
      backgroundBrightness: backgroundBrightness,
    );
    final washColor = intensity == null
        ? base
        : base.withValues(
            alpha: (base.a *
                    intensity.clamp(
                      kDetectionIntensityMin,
                      kDetectionIntensityMax,
                    ))
                .clamp(0.0, 1.0),
          );
    return ResolvedDetectionStyle(washColor: washColor, chipAccent: hue);
  }
}
