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
import 'package:mobissh/state/detection_providers.dart';
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

  // #1154: the resolver takes the GLOBAL intensity level (R11); medium is the
  // identity, so the golden test below is parameterised on it.
  DetectionStyleResolver emptyResolver(
    Brightness brightness, {
    DetectionIntensity intensity = DetectionIntensity.medium,
  }) =>
      DetectionStyleResolver(
        styles: DetectionStyles.empty,
        accent: accent,
        backgroundBrightness: brightness,
        intensity: intensity,
      );

  group('GOLDEN EQUALITY: empty store == today\'s constants', () {
    test('the wash color matches ghosttyBubbleWashColor exactly for every '
        'built-in pattern × state × luminance at intensity MEDIUM (R11 '
        'identity)', () {
      for (final brightness in Brightness.values) {
        final resolver =
            emptyResolver(brightness, intensity: DetectionIntensity.medium);
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

    test('R11: the resolver DEFAULTS to medium — a constructor without an '
        'intensity arg is bit-identical to the explicit medium one', () {
      for (final brightness in Brightness.values) {
        final implicit = DetectionStyleResolver(
          styles: DetectionStyles.empty,
          accent: accent,
          backgroundBrightness: brightness,
        );
        expect(implicit.intensity, DetectionIntensity.medium);
        for (final id in builtinIds) {
          for (final verified in [false, true]) {
            expect(
              implicit.resolveStyle(id, verified: verified),
              emptyResolver(brightness, intensity: DetectionIntensity.medium)
                  .resolveStyle(id, verified: verified),
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

  // #1154 (Slice 1 of #1153) — the GLOBAL intensity level composes over the
  // shipped derivation BEFORE the per-pattern Lab multiplier (R11): low =
  // HSL saturation ×0.6 + alpha ×0.6; medium = identity; high = saturation
  // ×1.25 (clamp 1.0) + alpha ×1.35 (clamp 1.0). Chips are untouched (R13).
  // The four kGhostty*WashAlpha* constants are NOT edited (R14) — these tests
  // assert the COMPOSED values per level against them.
  group('#1154 global intensity level (R11/R12/R13)', () {
    const levels = DetectionIntensity.values;
    // relpath is a built-in too (#1036) — it has a verified state.
    const allBuiltinIds = [...builtinIds, kGhosttyRelPathPatternId];

    double alphaAt(
      DetectionIntensity level,
      String id, {
      required bool verified,
      required Brightness brightness,
    }) =>
        emptyResolver(brightness, intensity: level)
            .resolveStyle(id, verified: verified)
            .washColor
            .a;

    double baseAlpha({required bool verified, required Brightness brightness}) =>
        ghosttyBubbleWashColor(
          accent,
          verified: verified,
          backgroundBrightness: brightness,
        ).a;

    test('R11: LOW is base alpha × 0.6 exactly; HIGH is base alpha × 1.35 '
        'clamped to 1.0 (per pattern × state × luminance)', () {
      for (final brightness in Brightness.values) {
        for (final id in allBuiltinIds) {
          for (final verified in [false, true]) {
            final base = baseAlpha(verified: verified, brightness: brightness);
            expect(
              alphaAt(
                DetectionIntensity.low,
                id,
                verified: verified,
                brightness: brightness,
              ),
              closeTo(base * 0.6, 1e-6),
              reason: 'low alpha for $id (verified=$verified, $brightness)',
            );
            expect(
              alphaAt(
                DetectionIntensity.high,
                id,
                verified: verified,
                brightness: brightness,
              ),
              closeTo((base * 1.35).clamp(0.0, 1.0), 1e-6),
              reason: 'high alpha for $id (verified=$verified, $brightness)',
            );
          }
        }
      }
    });

    test('R12: alpha(low) < alpha(medium) < alpha(high) for every built-in '
        'pattern × verified × luminance', () {
      for (final brightness in Brightness.values) {
        for (final id in allBuiltinIds) {
          for (final verified in [false, true]) {
            final low = alphaAt(
              DetectionIntensity.low,
              id,
              verified: verified,
              brightness: brightness,
            );
            final medium = alphaAt(
              DetectionIntensity.medium,
              id,
              verified: verified,
              brightness: brightness,
            );
            final high = alphaAt(
              DetectionIntensity.high,
              id,
              verified: verified,
              brightness: brightness,
            );
            expect(low, lessThan(medium),
                reason: '$id verified=$verified $brightness: low < medium');
            expect(medium, lessThan(high),
                reason: '$id verified=$verified $brightness: medium < high');
          }
        }
      }
    });

    test('R12: detected < verified INSIDE each level (the level composes '
        'before the pair clamp, so it cannot invert the pair)', () {
      for (final level in levels) {
        for (final brightness in Brightness.values) {
          for (final id in allBuiltinIds) {
            final detected = alphaAt(
              level,
              id,
              verified: false,
              brightness: brightness,
            );
            final verified = alphaAt(
              level,
              id,
              verified: true,
              brightness: brightness,
            );
            expect(detected, lessThan(verified),
                reason: '$level $id $brightness: detected < verified');
          }
        }
      }
    });

    test('R11: the LOW alpha stays >= 0.12 and the wash is never transparent '
        '(the #1074 tracking assertion keys on non-null / visible)', () {
      for (final brightness in Brightness.values) {
        for (final id in allBuiltinIds) {
          for (final verified in [false, true]) {
            final resolved = emptyResolver(
              brightness,
              intensity: DetectionIntensity.low,
            ).resolveStyle(id, verified: verified);
            expect(resolved.washColor, isNotNull);
            expect(
              resolved.washColor.a,
              greaterThanOrEqualTo(0.12),
              reason: 'low floor for $id verified=$verified $brightness',
            );
            expect(resolved.washColor.a, greaterThan(0.0));
          }
        }
      }
    });

    test('R11: HSL saturation orders low < medium <= high, hue preserved, '
        'and high clamps at 1.0', () {
      for (final brightness in Brightness.values) {
        for (final verified in [false, true]) {
          HSLColor hsl(DetectionIntensity level) => HSLColor.fromColor(
                emptyResolver(brightness, intensity: level)
                    .resolveStyle(kGhosttyUrlPatternId, verified: verified)
                    .washColor,
              );
          final low = hsl(DetectionIntensity.low);
          final medium = hsl(DetectionIntensity.medium);
          final high = hsl(DetectionIntensity.high);
          expect(low.saturation, lessThan(medium.saturation),
              reason: 'low desaturates ($brightness verified=$verified)');
          expect(medium.saturation, lessThanOrEqualTo(high.saturation),
              reason: 'high saturates ($brightness verified=$verified)');
          expect(high.saturation, lessThanOrEqualTo(1.0));
          // The exact factors on the test accent (S≈0.59, unclamped at high).
          expect(low.saturation, closeTo(medium.saturation * 0.6, 0.02));
          expect(
            high.saturation,
            closeTo((medium.saturation * 1.25).clamp(0.0, 1.0), 0.02),
          );
          // The hue family is the same at every level (one hue for the whole
          // affordance — only saturation/alpha move).
          expect(low.hue, closeTo(medium.hue, 1.0));
          expect(high.hue, closeTo(medium.hue, 1.0));
        }
      }
    });

    test('R11: HIGH saturation clamps to 1.0 on an already-saturated accent '
        '(no overflow / no wrap)', () {
      const saturated = Color(0xFFFF0000);
      final resolved = const DetectionStyleResolver(
        styles: DetectionStyles.empty,
        accent: saturated,
        backgroundBrightness: Brightness.dark,
        intensity: DetectionIntensity.high,
      ).resolveStyle(kGhosttyUrlPatternId, verified: false);
      final hsl = HSLColor.fromColor(resolved.washColor);
      expect(hsl.saturation, closeTo(1.0, 1e-6));
      expect(resolved.washColor.a, lessThanOrEqualTo(1.0));
    });

    test('R11: MEDIUM is the identity even with a colorHex override — the '
        'override hue is bit-exact (no HSL round-trip on the medium path)', () {
      const resolver = DetectionStyleResolver(
        styles: DetectionStyles({'url': DetectionPatternStyle(colorHex: '#33AA55')}),
        accent: accent,
        backgroundBrightness: Brightness.dark,
        intensity: DetectionIntensity.medium,
      );
      final resolved = resolver.resolveStyle('url', verified: false);
      expect(resolved.washColor.toARGB32() & 0x00FFFFFF, 0x0033AA55);
      expect(
        resolved.washColor.a,
        closeTo(kGhosttyBubbleDetectedWashAlphaOnDark, 1e-9),
      );
    });

    test('R13: chipAccent == accent and GutterMarkStyle.normal/bold.chipColor '
        'are IDENTICAL at ALL three levels (chips untouched by intensity)', () {
      for (final level in levels) {
        for (final brightness in Brightness.values) {
          final resolver = emptyResolver(brightness, intensity: level);
          for (final id in allBuiltinIds) {
            for (final verified in [false, true]) {
              final resolved = resolver.resolveStyle(id, verified: verified);
              expect(resolved.chipAccent, accent,
                  reason: '$level $id verified=$verified: chip accent');
              expect(
                GutterMarkStyle.normal.chipColor(resolved.chipAccent),
                GutterMarkStyle.normal.chipColor(accent),
              );
              expect(
                GutterMarkStyle.bold.chipColor(resolved.chipAccent),
                GutterMarkStyle.bold.chipColor(accent),
              );
              expect(
                GutterMarkStyle.normal.chipColor(resolved.chipAccent).a,
                1.0,
                reason: 'chip opacity stays 1.0 at $level',
              );
            }
          }
        }
      }
    });

    test('R13: a colorHex override still reaches the chip UNCHANGED at every '
        'level (the level never touches the chip hue)', () {
      for (final level in levels) {
        final resolver = DetectionStyleResolver(
          styles: const DetectionStyles({
            'url': DetectionPatternStyle(colorHex: '#33AA55'),
          }),
          accent: accent,
          backgroundBrightness: Brightness.dark,
          intensity: level,
        );
        final resolved = resolver.resolveStyle('url', verified: false);
        expect(resolved.chipAccent.toARGB32() & 0x00FFFFFF, 0x0033AA55,
            reason: '$level: chip hue is the raw override');
      }
    });

    test('R11/R23: the per-pattern Lab intensity composes ON TOP of the '
        'level — with activeIntensity 1.5, high >= medium >= low still holds '
        'and the pair clamp still keeps detected < verified', () {
      for (final brightness in Brightness.values) {
        double at(DetectionIntensity level, {required bool verified}) =>
            DetectionStyleResolver(
              styles: const DetectionStyles({
                kGhosttyPathPatternId: DetectionPatternStyle(
                  inactiveIntensity: 1.5,
                  activeIntensity: 1.5,
                ),
              }),
              accent: accent,
              backgroundBrightness: brightness,
              intensity: level,
            ).resolveStyle(kGhosttyPathPatternId, verified: verified).washColor.a;
        for (final verified in [false, true]) {
          final low = at(DetectionIntensity.low, verified: verified);
          final medium = at(DetectionIntensity.medium, verified: verified);
          final high = at(DetectionIntensity.high, verified: verified);
          expect(high, greaterThanOrEqualTo(medium),
              reason: 'tuned 1.5 $brightness verified=$verified: high >= medium');
          expect(medium, greaterThanOrEqualTo(low),
              reason: 'tuned 1.5 $brightness verified=$verified: medium >= low');
          expect(high, lessThanOrEqualTo(1.0));
          // The tuned medium value is the shipped Lab composition, untouched.
          expect(
            medium,
            closeTo(
              (baseAlpha(verified: verified, brightness: brightness) * 1.5)
                  .clamp(0.0, 1.0),
              1e-6,
            ),
          );
          // Low: the level scales the base FIRST, then the Lab multiplier.
          expect(
            low,
            closeTo(
              (baseAlpha(verified: verified, brightness: brightness) * 0.6 * 1.5)
                  .clamp(0.0, 1.0),
              1e-6,
            ),
          );
        }
        for (final level in levels) {
          expect(
            at(level, verified: false),
            lessThanOrEqualTo(at(level, verified: true)),
            reason: '$level $brightness: tuned detected <= verified',
          );
        }
      }
    });

    test('R11: the level is a resolver INPUT — a resolver rebuilt at another '
        'level resolves a different style (so the wash layer repaints)', () {
      const medium = DetectionStyleResolver(
        accent: accent,
        backgroundBrightness: Brightness.dark,
      );
      const low = DetectionStyleResolver(
        accent: accent,
        backgroundBrightness: Brightness.dark,
        intensity: DetectionIntensity.low,
      );
      expect(medium.intensity, isNot(low.intensity));
      expect(
        medium.resolveStyle(kGhosttyUrlPatternId, verified: false),
        isNot(equals(low.resolveStyle(kGhosttyUrlPatternId, verified: false))),
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
