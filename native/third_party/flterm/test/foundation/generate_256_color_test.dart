import 'package:flterm/src/foundation/generate_256_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generate256Color', () {
    const bg = Color(0xFF181818);
    const fg = Color(0xFFD8D8D8);

    const ansiColors = [
      Color(0xFF282828),
      Color(0xFFCC4242),
      Color(0xFF66994C),
      Color(0xFFE5B566),
      Color(0xFF668ECC),
      Color(0xFFB266B2),
      Color(0xFF4CB2B2),
      Color(0xFFAAAAAA),
      Color(0xFF505050),
      Color(0xFFE66464),
      Color(0xFF8CBE6E),
      Color(0xFFF0C878),
      Color(0xFF82A0DC),
      Color(0xFFC882C8),
      Color(0xFF64C8C8),
      Color(0xFFDCDCDC),
    ];

    void expectBaseColors(List<Color> colors) {
      for (var i = 0; i < 16; i++) {
        expect(colors[i], ansiColors[i], reason: 'index $i');
      }
    }

    double luma(Color color) {
      return 0.299 * color.r * 255 +
          0.587 * color.g * 255 +
          0.114 * color.b * 255;
    }

    void expectGeneratedGrayscaleRamp(List<Color> colors) {
      for (var i = 233; i < 256; i++) {
        expect(
          luma(colors[i]),
          greaterThanOrEqualTo(luma(colors[i - 1])),
          reason: 'index $i should not be darker than ${i - 1}',
        );
      }
    }

    test('returns exactly 256 entries', () {
      final result = generate256Color(
        base: ansiColors,
        background: bg,
        foreground: fg,
      );
      expect(result.length, 256);
    });

    test('preserves base colors', () {
      final result = generate256Color(
        base: ansiColors,
        background: bg,
        foreground: fg,
      );

      expectBaseColors(result);
    });

    test('returns generated cube corners', () {
      final result = generate256Color(
        base: ansiColors,
        background: bg,
        foreground: fg,
      );
      expect(result[16], bg);
      expect(result[231], fg);
    });

    test('keeps grayscale ramp monotonically non-darkening', () {
      final result = generate256Color(
        base: ansiColors,
        background: bg,
        foreground: fg,
      );

      expectGeneratedGrayscaleRamp(result);
    });

    test('light theme without harmonious swaps orientation so cube runs '
        'dark→light', () {
      const lightBg = Color(0xFFF0F0F0);
      const lightFg = Color(0xFF1E1E1E);
      final result = generate256Color(
        base: ansiColors,
        background: lightBg,
        foreground: lightFg,
      );
      expect(result[16], lightFg);
    });

    test('skip set preserves specified base indices unchanged', () {
      final customBase = List<Color>.from(ansiColors);
      const custom = Color(0xFF7B2D43);
      customBase[0] = custom;
      final result = generate256Color(
        base: customBase,
        background: bg,
        foreground: fg,
        skip: {0},
      );
      expect(result[0], custom);
      expect(result[16], bg);
      expect(result[231], fg);
    });

    test('requires exactly 16 base colors', () {
      expect(
        () => generate256Color(
          base: const [Color(0xFF000000)],
          background: bg,
          foreground: fg,
        ),
        throwsArgumentError,
      );
    });
  });
}
