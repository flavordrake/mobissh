import 'package:flterm/src/foundation/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cellFg = Color(0xFF112233);
  const cellBg = Color(0xFF445566);

  group('DynamicColor', () {
    group('fixed', () {
      test('resolves to the fixed color', () {
        const color = DynamicColor.fixed(Color(0xFFAA00FF));
        expect(
          color.resolve(cellForeground: cellFg, cellBackground: cellBg),
          const Color(0xFFAA00FF),
        );
      });

      test('exposes fixedColor', () {
        expect(
          const DynamicColor.fixed(Color(0xFF123456)).fixedColor,
          const Color(0xFF123456),
        );
      });

      test('compares by value', () {
        const a = DynamicColor.fixed(Color(0xFF123456));
        const b = DynamicColor.fixed(Color(0xFF123456));
        const c = DynamicColor.fixed(Color(0xFF654321));
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(equals(c)));
      });
    });

    group('cellForeground', () {
      test('resolves to cell foreground', () {
        const color = DynamicColor.cellForeground();
        expect(
          color.resolve(cellForeground: cellFg, cellBackground: cellBg),
          cellFg,
        );
      });

      test('returns null fixedColor', () {
        expect(const DynamicColor.cellForeground().fixedColor, isNull);
      });

      test('compares all instances equally', () {
        expect(
          const DynamicColor.cellForeground(),
          equals(const DynamicColor.cellForeground()),
        );
      });
    });

    group('cellBackground', () {
      test('resolves to cell background', () {
        const color = DynamicColor.cellBackground();
        expect(
          color.resolve(cellForeground: cellFg, cellBackground: cellBg),
          cellBg,
        );
      });

      test('returns null fixedColor', () {
        expect(const DynamicColor.cellBackground().fixedColor, isNull);
      });
    });

    group('equality', () {
      test('distinguishes variants', () {
        expect(
          const DynamicColor.fixed(Color(0xFF112233)),
          isNot(equals(const DynamicColor.cellForeground())),
        );
        expect(
          const DynamicColor.cellForeground(),
          isNot(equals(const DynamicColor.cellBackground())),
        );
      });
    });
  });
}
