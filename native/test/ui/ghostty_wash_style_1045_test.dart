// #1045 — the app half of the behind-glyph wash: [ghosttyWashHighlightStyle]
// is the pure core the view installs as the controller's
// `detectionHighlightStyleOf` resolver. It must compose EXACTLY the gates the
// retired widget-layer overlay applied — pattern routing (command stays
// gutter-only, customs get the wash), the #990/#995 visibility suppression,
// the #990 verified shade — over the #1031 style resolver, and an EMPTY store
// must reproduce the shipped #1000 wash derivation bit-identically (the
// zero-visual-change invariant carried over from the seam tests).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/ui/detection_style_resolver.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

const _accent = Color(0xFF5B9BD5);

Color _resolverWash(
  DetectionStyleResolver resolver,
  String patternId, {
  required bool verified,
}) => resolver.resolveStyle(patternId, verified: verified).washColor;

void main() {
  group('ghosttyPatternPaintsWash (#1045 pattern routing)', () {
    test('url / osc8 / path / relpath / custom.* paint the wash', () {
      expect(ghosttyPatternPaintsWash(kGhosttyUrlPatternId), isTrue);
      expect(ghosttyPatternPaintsWash(kGhosttyOsc8PatternId), isTrue);
      expect(ghosttyPatternPaintsWash(kGhosttyPathPatternId), isTrue);
      expect(ghosttyPatternPaintsWash(kGhosttyRelPathPatternId), isTrue);
      expect(ghosttyPatternPaintsWash('custom.my-tickets'), isTrue);
    });

    test('the command BLOCK pattern stays gutter-only (#998 C)', () {
      expect(ghosttyPatternPaintsWash(kGhosttyCommandPatternId), isFalse);
    });

    test('unknown ids paint nothing', () {
      expect(ghosttyPatternPaintsWash('selection'), isFalse);
    });
  });

  group('ghosttyWashHighlightStyle', () {
    const resolver = DetectionStyleResolver(
      styles: DetectionStyles.empty,
      accent: _accent,
      backgroundBrightness: Brightness.dark,
    );
    Color washColorOf(String patternId, {required bool verified}) =>
        _resolverWash(resolver, patternId, verified: verified);

    test('a visible URL anchor gets a CAPSULE background from the resolver',
        () {
      final style = ghosttyWashHighlightStyle(
        patternId: kGhosttyUrlPatternId,
        visible: true,
        verified: false,
        washColorOf: washColorOf,
      );
      expect(style, isNotNull);
      expect(style!.capsule, isTrue,
          reason: 'the wash IS the capsule look, drawn by the fork');
      expect(style.underline, isNull);
      // ZERO CHANGE: an empty store composes to the shipped #1000 derivation.
      expect(
        style.background,
        ghosttyBubbleWashColor(
          _accent,
          verified: false,
          backgroundBrightness: Brightness.dark,
        ),
      );
    });

    test('a VERIFIED path anchor gets the bolder #990 shade', () {
      final style = ghosttyWashHighlightStyle(
        patternId: kGhosttyPathPatternId,
        visible: true,
        verified: true,
        washColorOf: washColorOf,
      )!;
      expect(
        style.background,
        ghosttyBubbleWashColor(
          _accent,
          verified: true,
          backgroundBrightness: Brightness.dark,
        ),
      );
    });

    test('a SUPPRESSED anchor paints NOTHING (#990/#995 one seam)', () {
      final style = ghosttyWashHighlightStyle(
        patternId: kGhosttyPathPatternId,
        visible: false,
        verified: false,
        washColorOf: washColorOf,
      );
      expect(style, isNull);
    });

    test('the command block resolves to no style regardless of visibility',
        () {
      final style = ghosttyWashHighlightStyle(
        patternId: kGhosttyCommandPatternId,
        visible: true,
        verified: false,
        washColorOf: washColorOf,
      );
      expect(style, isNull);
    });

    test('a stored override flows through (Detection Lab live-apply)', () {
      const overrideWash = Color(0x4D33AA55);
      final style = ghosttyWashHighlightStyle(
        patternId: kGhosttyUrlPatternId,
        visible: true,
        verified: false,
        washColorOf: (id, {required bool verified}) =>
            id == kGhosttyUrlPatternId
                ? overrideWash
                : washColorOf(id, verified: verified),
      )!;
      expect(style.background, overrideWash);
    });

    test('custom patterns get the same inline wash (#1031 slice 3)', () {
      final style = ghosttyWashHighlightStyle(
        patternId: 'custom.my-tickets',
        visible: true,
        verified: false,
        washColorOf: washColorOf,
      );
      expect(style, isNotNull);
      expect(style!.capsule, isTrue);
    });
  });
}
