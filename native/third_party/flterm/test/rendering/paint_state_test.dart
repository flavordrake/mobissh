import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TerminalPaintState', () {
    final theme = TerminalTheme.dark();
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    group('constructor', () {
      test('computes derived fields from theme', () {
        final state = TerminalPaintState(theme, metrics);

        expect(state.theme, theme);
        expect(state.metrics, metrics);
        expect(state.faintAlpha, (theme.faintOpacity * 255).ceil());
        expect(state.terminalForegroundArgb, theme.foreground.toARGB32());
        expect(state.terminalBackgroundArgb, theme.background.toARGB32());
      });
    });

    group('updateTheme', () {
      test('recomputes derived fields', () {
        final state = TerminalPaintState(theme, metrics);
        final light = TerminalTheme.light();

        state.updateTheme(light);

        expect(state.theme, light);
        expect(state.faintAlpha, (light.faintOpacity * 255).ceil());
      });

      test('faintAlpha reflects new faintOpacity', () {
        final state = TerminalPaintState(theme, metrics);

        state.updateTheme(theme.copyWith(faintOpacity: 0.0));
        expect(state.faintAlpha, 0);

        state.updateTheme(theme.copyWith(faintOpacity: 1.0));
        expect(state.faintAlpha, 255);
      });
    });

    group('mutable state', () {
      test('starts with default frame state', () {
        final state = TerminalPaintState(theme, metrics);

        expect(state.rows, 0);
        expect(state.cols, 0);
        expect(state.blinkVisible, isTrue);
        expect(state.selection, isNull);
        expect(state.viewportOffset, 0);
        expect(state.cursorWide, isFalse);
        expect(state.cursorFocused, isTrue);
      });
    });
  });
}
