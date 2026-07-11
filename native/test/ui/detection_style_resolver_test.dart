// #1031 slice 1 — the detection style RESOLVER: the single composition point
// both the runtime affordances (bubble wash + gutter chip) and the future lab
// preview read. Composes: stored override → the #1000 luminance-tuned base
// alphas × a clamped intensity multiplier → the per-session accent when no
// colorHex override exists.
//
// THE INVARIANT (zero visual change): a resolver over an EMPTY store must
// reproduce today's exact colors/alphas — ghosttyBubbleWashColor for the wash,
// the raw session accent for the chip — for every built-in pattern, both
// states, both theme luminances. That equality IS the golden test for this
// slice.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/ui/detection_style_resolver.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

void main() {
  // A typical translucent session selection accent (the runtime hands the
  // resolver `palette.theme.selection` as-is).
  const accent = Color(0x335B9BD5);
  const builtinIds = [
    kGhosttyUrlPatternId,
    kGhosttyOsc8PatternId,
    kGhosttyPathPatternId,
    kGhosttyCommandPatternId,
  ];

  DetectionStyleResolver emptyResolver(Brightness brightness) =>
      DetectionStyleResolver(
        styles: DetectionStyles.empty,
        accent: accent,
        backgroundBrightness: brightness,
      );

  group('GOLDEN EQUALITY: empty store == today\'s constants', () {
    test('the wash color matches ghosttyBubbleWashColor exactly for every '
        'built-in pattern × state × luminance', () {
      for (final brightness in Brightness.values) {
        final resolver = emptyResolver(brightness);
        for (final id in builtinIds) {
          for (final verified in [false, true]) {
            final resolved = resolver.resolveStyle(id, verified: verified);
            expect(
              resolved.washColor,
              ghosttyBubbleWashColor(
                accent,
                verified: verified,
                backgroundBrightness: brightness,
              ),
              reason: 'no-override wash must be bit-identical for $id '
                  '(verified=$verified, $brightness)',
            );
          }
        }
      }
    });

    test('the chip accent is the raw session accent — GutterMarkStyle '
        'derives the SAME opaque chip from it', () {
      for (final brightness in Brightness.values) {
        final resolver = emptyResolver(brightness);
        for (final id in builtinIds) {
          final resolved = resolver.resolveStyle(id, verified: false);
          expect(resolved.chipAccent, accent);
          expect(
            GutterMarkStyle.normal.chipColor(resolved.chipAccent),
            GutterMarkStyle.normal.chipColor(accent),
          );
          expect(
            GutterMarkStyle.bold.chipColor(resolved.chipAccent),
            GutterMarkStyle.bold.chipColor(accent),
          );
        }
      }
    });

    test('an unknown / custom pattern id with no override also resolves to '
        'the defaults (no assumption ids come from the built-in set)', () {
      final resolved = emptyResolver(Brightness.dark)
          .resolveStyle('custom.jira', verified: false);
      expect(
        resolved.washColor,
        ghosttyBubbleWashColor(
          accent,
          verified: false,
          backgroundBrightness: Brightness.dark,
        ),
      );
      expect(resolved.chipAccent, accent);
    });
  });

  group('colorHex override', () {
    DetectionStyleResolver resolverWith(DetectionPatternStyle style) =>
        DetectionStyleResolver(
          styles: DetectionStyles({'url': style}),
          accent: accent,
          backgroundBrightness: Brightness.dark,
        );

    test('replaces the hue for BOTH wash and chip, keeping the tuned alpha',
        () {
      final resolver =
          resolverWith(const DetectionPatternStyle(colorHex: '#33AA55'));
      final resolved = resolver.resolveStyle('url', verified: false);
      // Same alpha as the untouched default…
      expect(
        resolved.washColor.a,
        closeTo(kGhosttyBubbleDetectedWashAlphaOnDark, 1e-9),
      );
      // …but the override hue.
      expect(resolved.washColor.toARGB32() & 0x00FFFFFF, 0x0033AA55);
      expect(resolved.chipAccent.toARGB32() & 0x00FFFFFF, 0x0033AA55);
    });

    test('only overrides ITS pattern — others keep the session accent', () {
      final resolver =
          resolverWith(const DetectionPatternStyle(colorHex: '#33AA55'));
      expect(resolver.resolveStyle('path', verified: false).chipAccent, accent);
    });

    test('an INVALID colorHex is ignored (falls back to the accent)', () {
      for (final bad in ['', '#12', 'zzzzzz', '#GGGGGG', '#12345']) {
        final resolver =
            resolverWith(DetectionPatternStyle(colorHex: bad));
        final resolved = resolver.resolveStyle('url', verified: false);
        expect(
          resolved.washColor,
          ghosttyBubbleWashColor(
            accent,
            verified: false,
            backgroundBrightness: Brightness.dark,
          ),
          reason: '"$bad" must not change the wash',
        );
        expect(resolved.chipAccent, accent);
      }
    });
  });

  group('intensity multipliers', () {
    DetectionStyleResolver resolverWith(
      DetectionPatternStyle style, {
      String id = 'path',
      Brightness brightness = Brightness.dark,
    }) =>
        DetectionStyleResolver(
          styles: DetectionStyles({id: style}),
          accent: accent,
          backgroundBrightness: brightness,
        );

    test('inactiveIntensity scales the DETECTED base alpha (per luminance)',
        () {
      for (final brightness in Brightness.values) {
        final base = ghosttyBubbleWashColor(
          accent,
          verified: false,
          backgroundBrightness: brightness,
        ).a;
        final resolved = resolverWith(
          const DetectionPatternStyle(inactiveIntensity: 1.5),
          brightness: brightness,
        ).resolveStyle('path', verified: false);
        expect(resolved.washColor.a, closeTo(base * 1.5, 0.01));
      }
    });

    test('activeIntensity scales the VERIFIED base alpha and does NOT touch '
        'the detected state', () {
      final baseVerified = ghosttyBubbleWashColorVerifiedAlphaOnDark();
      final resolver = resolverWith(
        const DetectionPatternStyle(activeIntensity: 0.5),
      );
      expect(
        resolver.resolveStyle('path', verified: true).washColor.a,
        closeTo(baseVerified * 0.5, 0.01),
      );
      expect(
        resolver.resolveStyle('path', verified: false).washColor.a,
        closeTo(kGhosttyBubbleDetectedWashAlphaOnDark, 1e-9),
        reason: 'activeIntensity is per-STATE — detected stays default',
      );
    });

    test('intensity NEVER changes the chip accent (chips stay opaque by '
        'design — the wash is what intensity governs)', () {
      final resolver = resolverWith(
        const DetectionPatternStyle(inactiveIntensity: 0.3),
      );
      expect(resolver.resolveStyle('path', verified: false).chipAccent, accent);
    });

    test('the multiplier is clamped to the band and the alpha to [0,1]', () {
      final resolvedHigh = resolverWith(
        const DetectionPatternStyle(activeIntensity: 100.0),
        brightness: Brightness.light,
      ).resolveStyle('path', verified: true);
      // #1053: with the behind-glyphs verified base raised, base × maxIntensity
      // exceeds 1.0, so the alpha saturates at the [0,1] ceiling (the multiplier
      // is still clamped to the band first — both clamps engage).
      expect(
        resolvedHigh.washColor.a,
        closeTo(
          (kGhosttyBubbleVerifiedWashAlphaOnLight * kDetectionIntensityMax)
              .clamp(0.0, 1.0),
          0.01,
        ),
      );
      expect(resolvedHigh.washColor.a, lessThanOrEqualTo(1.0));

      final resolvedLow = resolverWith(
        const DetectionPatternStyle(inactiveIntensity: 0.0),
      ).resolveStyle('path', verified: false);
      expect(
        resolvedLow.washColor.a,
        closeTo(
          kGhosttyBubbleDetectedWashAlphaOnDark * kDetectionIntensityMin,
          0.01,
        ),
        reason: 'a zero multiplier must not make the wash vanish — the band '
            'floor keeps every stored value visible (IA review change 6)',
      );
    });
  });

  group('per-pattern REAL states (IA review change 1: no dead controls)', () {
    test('only PATH has an active (verified) state today (#990)', () {
      expect(detectionPatternHasActiveState(kGhosttyPathPatternId), isTrue);
      expect(detectionPatternHasActiveState(kGhosttyUrlPatternId), isFalse);
      expect(detectionPatternHasActiveState(kGhosttyOsc8PatternId), isFalse);
      expect(
        detectionPatternHasActiveState(kGhosttyCommandPatternId),
        isFalse,
      );
    });

    test('a custom pattern id has NO active state (until pressed-state ships)',
        () {
      expect(detectionPatternHasActiveState('custom.jira'), isFalse);
    });
  });

  group('#1031 slice 2 — intensity pair (review change 6: no inversion)', () {
    test('a non-conflicting pair passes through unchanged', () {
      final pair = detectionResolveIntensityPair(
        inactive: 0.8,
        active: 1.3,
        activeDragged: false,
      );
      expect(pair.inactive, 0.8);
      expect(pair.active, 1.3);
    });

    test('dragging DETECTED up past active PUSHES active up by the gap', () {
      final pair = detectionResolveIntensityPair(
        inactive: 1.3,
        active: 1.3,
        activeDragged: false,
      );
      expect(pair.inactive, 1.3);
      expect(pair.active, closeTo(1.3 + kDetectionIntensityGap, 1e-9));
    });

    test('dragging ACTIVE down past detected PUSHES detected down by the gap',
        () {
      final pair = detectionResolveIntensityPair(
        inactive: 1.0,
        active: 0.9,
        activeDragged: true,
      );
      expect(pair.active, 0.9);
      expect(pair.inactive, closeTo(0.9 - kDetectionIntensityGap, 1e-9));
    });

    test('the push respects the band: detected caps at max - gap', () {
      final pair = detectionResolveIntensityPair(
        inactive: kDetectionIntensityMax,
        active: 1.0,
        activeDragged: false,
      );
      expect(pair.active, kDetectionIntensityMax);
      expect(
        pair.inactive,
        closeTo(kDetectionIntensityMax - kDetectionIntensityGap, 1e-9),
      );
    });

    test('the push respects the band: active floors at min + gap', () {
      final pair = detectionResolveIntensityPair(
        inactive: 1.0,
        active: kDetectionIntensityMin,
        activeDragged: true,
      );
      expect(pair.inactive, kDetectionIntensityMin);
      expect(
        pair.active,
        closeTo(kDetectionIntensityMin + kDetectionIntensityGap, 1e-9),
      );
    });

    test('out-of-band inputs clamp into the band first', () {
      final pair = detectionResolveIntensityPair(
        inactive: 0.0,
        active: 9.0,
        activeDragged: false,
      );
      expect(pair.inactive, kDetectionIntensityMin);
      expect(pair.active, kDetectionIntensityMax);
    });
  });
}

/// The verified-on-dark base alpha via the shipped derivation (keeps the test
/// honest against the constant it multiplies).
double ghosttyBubbleWashColorVerifiedAlphaOnDark() => ghosttyBubbleWashColor(
      const Color(0x335B9BD5),
      verified: true,
      backgroundBrightness: Brightness.dark,
    ).a;
