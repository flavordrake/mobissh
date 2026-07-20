// Unit tests for the #1086 large-landscape layout signal.
//
// Gate semantics (owner 2026-07-20): "obvious tablet" only — landscape AND an
// expanded width (≥ 840dp) AND a tablet-class shortest side (≥ 600dp). Big in
// BOTH dimensions, so a phone in landscape (wide but short) no longer trips the
// desktop-style chrome, and the 800×600 test canvas stays on the phone layout.

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/util/large_landscape.dart';

void main() {
  group('isLargeLandscape (#1086)', () {
    test('phone portrait is not large-landscape', () {
      expect(isLargeLandscape(const Size(412, 915)), isFalse);
    });

    test('phone rotated to landscape (narrow) is not large-landscape', () {
      // Pixel-class phone in landscape: under both thresholds.
      expect(isLargeLandscape(const Size(760, 412)), isFalse);
    });

    test('LARGE phone in landscape is not large-landscape', () {
      // The exact owner complaint: a big phone in landscape is ~915dp wide —
      // it clears the expanded WIDTH (≥840) but its short edge (412) is well
      // under 600, so it must NOT get the tablet layout.
      expect(isLargeLandscape(const Size(915, 412)), isFalse);
    });

    test('800x600 (Flutter default test canvas) is not large-landscape', () {
      // Short edge 600 clears the tablet threshold, but width 800 < 840, so it
      // stays phone — terminal-chrome tests that use the default canvas keep
      // their phone layout.
      expect(isLargeLandscape(const Size(800, 600)), isFalse);
    });

    test('tablet landscape is large-landscape', () {
      expect(isLargeLandscape(const Size(1280, 800)), isTrue);
    });

    test('desktop-mode / desktop-web wide window is large-landscape', () {
      expect(isLargeLandscape(const Size(1600, 900)), isTrue);
    });

    test('wide but portrait (tall) is not large-landscape', () {
      expect(isLargeLandscape(const Size(900, 1400)), isFalse);
    });

    test('at both thresholds, landscape, qualifies', () {
      // width == 840, shortest side == 600, landscape.
      expect(isLargeLandscape(const Size(840, 600)), isTrue);
    });

    test('one px below the width threshold does not qualify', () {
      expect(isLargeLandscape(const Size(839, 600)), isFalse);
    });

    test('one px below the shortest-side threshold does not qualify', () {
      // Wide enough (1000 ≥ 840) but short edge 599 < 600.
      expect(isLargeLandscape(const Size(1000, 599)), isFalse);
    });
  });
}
