// Unit tests for the #1086 large-landscape layout signal.

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/util/large_landscape.dart';

void main() {
  group('isLargeLandscape (#1086)', () {
    test('phone portrait is not large-landscape', () {
      expect(isLargeLandscape(const Size(412, 915)), isFalse);
    });

    test('phone rotated to landscape (narrow) is not large-landscape', () {
      // Pixel-class phone in landscape: wide-ish but under the 840dp threshold.
      expect(isLargeLandscape(const Size(760, 412)), isFalse);
    });

    test('tablet landscape is large-landscape', () {
      expect(isLargeLandscape(const Size(1280, 800)), isTrue);
    });

    test('desktop-mode freeform wide window is large-landscape', () {
      expect(isLargeLandscape(const Size(1600, 900)), isTrue);
    });

    test('wide but portrait (tall) is not large-landscape', () {
      // A tall window wider than 840 but still portrait (height > width).
      expect(isLargeLandscape(const Size(900, 1400)), isFalse);
    });

    test('exactly at the width threshold, landscape, qualifies', () {
      expect(isLargeLandscape(const Size(840, 600)), isTrue);
    });

    test('one px below the threshold does not qualify', () {
      expect(isLargeLandscape(const Size(839, 600)), isFalse);
    });
  });
}
