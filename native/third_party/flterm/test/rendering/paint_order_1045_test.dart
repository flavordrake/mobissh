@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

import 'helpers/font_loader.dart';

/// #1045 paint-order proof: a highlight background fill renders BENEATH the
/// glyph paint. The whole point of routing the detection wash through the
/// fork's highlight pass is that glyphs stay full-contrast ON TOP of the fill
/// — so with an OPAQUE fill under a full-block glyph, the glyph pixel must
/// read back the FOREGROUND color (glyphs painted after the fill), while a
/// space cell inside the same range reads back the fill (proving the fill
/// painted at all). If the highlight pass ever moved above the text pass,
/// the glyph probe would read the fill color and this test would fail.
void main() {
  setUpAll(loadBundledFonts);

  const fill = Color(0xFFEE1100); // opaque: an over-glyph fill would WIN
  const cols = 10;
  const rows = 2;

  testWidgets('highlight fill paints BENEATH glyphs (opaque-fill probe)', (
    tester,
  ) async {
    final theme = TerminalTheme.dark().copyWith(
      fontSize: 24.0,
      fontFamilyFallback: bundledFontFamilyFallback,
    );
    final metrics = measureCellMetrics(
      fontFamily: theme.fontFamily,
      fontSize: theme.fontSize,
      fontData: jetBrainsMonoBytes,
    );
    final terminal = Terminal(cols: cols, rows: rows);
    addTearDown(terminal.dispose);
    // Row 0: full block, space, full block — the range covers all three.
    terminal.write(Uint8List.fromList(utf8.encode('█ █')));

    final renderCache = TerminalRenderCache();
    addTearDown(renderCache.dispose);

    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: cols * metrics.cellWidth,
                maxHeight: rows * metrics.cellHeight,
              ),
              child: TerminalRenderer(
                terminal: terminal,
                theme: theme,
                metrics: metrics,
                offset: ViewportOffset.zero(),
                renderCache: renderCache,
                renderObserver: const _HighlightObserver([
                  HighlightRange(
                    startRow: 0,
                    startCol: 0,
                    endRow: 0,
                    endCol: 3,
                    background: fill,
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );

    // captureImage/toByteData complete on REAL async work (raster thread) —
    // run them outside the fake-async test zone or they never resolve.
    late final ByteData bytes;
    late final int width;
    await tester.runAsync(() async {
      final image = await captureImage(
        find.byType(TerminalRenderer).evaluate().single,
      );
      bytes = (await image.toByteData())!;
      width = image.width;
      image.dispose();
    });

    int argbAtCellCenter(int col, int row) {
      final x = ((col + 0.5) * metrics.cellWidth).round();
      final y = ((row + 0.5) * metrics.cellHeight).round();
      final offset = (y * width + x) * 4;
      final r = bytes.getUint8(offset);
      final g = bytes.getUint8(offset + 1);
      final b = bytes.getUint8(offset + 2);
      final a = bytes.getUint8(offset + 3);
      return (a << 24) | (r << 16) | (g << 8) | b;
    }

    // The SPACE cell inside the range shows the fill — the highlight painted.
    expect(
      argbAtCellCenter(1, 0),
      fill.toARGB32(),
      reason: 'the highlight fill must be visible on a glyph-free cell',
    );
    // The FULL-BLOCK cells read back the foreground: glyphs paint ON TOP of
    // the (opaque) fill, i.e. the fill is BENEATH the glyph paint.
    expect(
      argbAtCellCenter(0, 0),
      theme.foreground.toARGB32(),
      reason: 'glyph ink must stay full-contrast OVER the highlight fill',
    );
    expect(argbAtCellCenter(2, 0), theme.foreground.toARGB32());
  });
}

class _HighlightObserver implements TerminalRenderObserver {
  const _HighlightObserver(this.highlights);

  @override
  final List<HighlightRange> highlights;

  @override
  TerminalSelection? get selection => null;

  @override
  bool get hasFocus => true;

  @override
  void reportPaintedViewportOffset(int offset) {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
