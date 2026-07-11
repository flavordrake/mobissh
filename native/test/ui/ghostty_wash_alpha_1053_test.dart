// #1053 / #1060 — the behind-glyphs wash must be visible but SECONDARY.
// Since #1045 the fill composites UNDER full-brightness glyphs over a near-black
// terminal cell background. #1053 re-tuned the old over-glyphs alphas (0.26/0.42)
// UP to clear a visibility floor; #1060 (owner P0 on +138) dialled them back
// DOWN — 0.55 detected was "much too intense" and dominated the text. These now
// assert the alphas sit in the #1060 band: above a low visibility floor, below a
// "not overpowering" ceiling for DETECTED, detected < verified with a clear
// margin, and that the Detection Lab intensity multiplier still composes on top.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/ui/detection_style_resolver.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

/// The alpha below which a translucent green wash over a near-black terminal
/// background reads as "near-invisible" (the +136/#1045 regression state).
/// #1060 lowered the DETECTED base under the old #1053 floor (0.45), so the
/// floor tracks the new quiet-but-visible target.
const double _kVisibilityFloor = 0.28;

/// #1060 "not overpowering" ceiling for the DETECTED wash — above this the fill
/// dominates the glyphs it annotates (the +138 complaint). Verified is allowed
/// to run stronger (it is the confirmed-existence shade), so this bounds detected
/// only.
const double _kDetectedCeiling = 0.42;

/// The minimum margin verified must keep above detected so the two states stay
/// visually distinct at phone density.
const double _kMinSeparation = 0.10;

void main() {
  group('#1060 behind-glyphs wash alphas sit in the visible-but-secondary band',
      () {
    test('every wash alpha is at or above the visibility floor (both themes)',
        () {
      expect(kGhosttyBubbleDetectedWashAlphaOnDark,
          greaterThanOrEqualTo(_kVisibilityFloor));
      expect(kGhosttyBubbleDetectedWashAlphaOnLight,
          greaterThanOrEqualTo(_kVisibilityFloor));
      expect(kGhosttyBubbleVerifiedWashAlphaOnDark,
          greaterThanOrEqualTo(_kVisibilityFloor));
      expect(kGhosttyBubbleVerifiedWashAlphaOnLight,
          greaterThanOrEqualTo(_kVisibilityFloor));
    });

    test('the DETECTED wash stays below the "not overpowering" ceiling (#1060)',
        () {
      expect(kGhosttyBubbleDetectedWashAlphaOnDark,
          lessThanOrEqualTo(_kDetectedCeiling));
      expect(kGhosttyBubbleDetectedWashAlphaOnLight,
          lessThanOrEqualTo(_kDetectedCeiling));
    });

    test('detected stays clearly below verified on both themes', () {
      expect(
        kGhosttyBubbleVerifiedWashAlphaOnDark -
            kGhosttyBubbleDetectedWashAlphaOnDark,
        greaterThanOrEqualTo(_kMinSeparation),
      );
      expect(
        kGhosttyBubbleVerifiedWashAlphaOnLight -
            kGhosttyBubbleDetectedWashAlphaOnLight,
        greaterThanOrEqualTo(_kMinSeparation),
      );
    });

    test('all alphas stay within a sane [floor, 1.0] range', () {
      for (final a in [
        kGhosttyBubbleDetectedWashAlphaOnDark,
        kGhosttyBubbleDetectedWashAlphaOnLight,
        kGhosttyBubbleVerifiedWashAlphaOnDark,
        kGhosttyBubbleVerifiedWashAlphaOnLight,
      ]) {
        expect(a, lessThanOrEqualTo(1.0));
        expect(a, greaterThanOrEqualTo(_kVisibilityFloor));
      }
    });
  });

  group('#1053 ghosttyBubbleWashColor carries the re-tuned alphas', () {
    const accent = Color(0xFF5B9BD5);

    test('the composed wash alpha matches the re-tuned constant per state', () {
      expect(
        ghosttyBubbleWashColor(accent,
                verified: false, backgroundBrightness: Brightness.dark)
            .a,
        closeTo(kGhosttyBubbleDetectedWashAlphaOnDark, 1e-9),
      );
      expect(
        ghosttyBubbleWashColor(accent,
                verified: true, backgroundBrightness: Brightness.dark)
            .a,
        closeTo(kGhosttyBubbleVerifiedWashAlphaOnDark, 1e-9),
      );
      expect(
        ghosttyBubbleWashColor(accent,
                verified: false, backgroundBrightness: Brightness.light)
            .a,
        closeTo(kGhosttyBubbleDetectedWashAlphaOnLight, 1e-9),
      );
      expect(
        ghosttyBubbleWashColor(accent,
                verified: true, backgroundBrightness: Brightness.light)
            .a,
        closeTo(kGhosttyBubbleVerifiedWashAlphaOnLight, 1e-9),
      );
    });
  });

  group('#1053 the Detection Lab intensity band still multiplies the new base',
      () {
    const accent = Color(0xFF5B9BD5);

    test('a mid-band multiplier scales the raised detected base', () {
      const resolver = DetectionStyleResolver(
        styles: DetectionStyles.empty,
        accent: accent,
        backgroundBrightness: Brightness.dark,
      );
      final base = resolver.resolveStyle('url', verified: false).washColor.a;
      // Empty store → base is the shipped constant, unmultiplied.
      expect(base, closeTo(kGhosttyBubbleDetectedWashAlphaOnDark, 1e-9));

      final scaled = DetectionStyleResolver(
        styles: const DetectionStyles({
          'path': DetectionPatternStyle(inactiveIntensity: 1.2),
        }),
        accent: accent,
        backgroundBrightness: Brightness.dark,
      ).resolveStyle('path', verified: false).washColor.a;
      expect(
        scaled,
        closeTo(
          (kGhosttyBubbleDetectedWashAlphaOnDark * 1.2).clamp(0.0, 1.0),
          0.01,
        ),
      );
    });
  });
}
