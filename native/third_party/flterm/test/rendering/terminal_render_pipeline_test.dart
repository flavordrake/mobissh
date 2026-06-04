@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/highlight_range.dart';
import 'package:flterm/src/foundation/terminal_selection.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/terminal_render_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('TerminalRenderPipeline', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    AtlasConfig config({double fontSize = 14}) {
      return AtlasConfig(
        fontSize: fontSize,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: metrics,
        devicePixelRatio: 1.0,
      );
    }

    void paint(TerminalRenderPipeline pipeline) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      pipeline.paint(canvas);
      recorder.endRecording().dispose();
    }

    void writeUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    late Terminal terminal;
    late Atlas atlas;
    late TerminalPaintState state;
    late TerminalRenderPipeline pipeline;

    setUp(() {
      terminal = Terminal(cols: 8, rows: 2);
      atlas = Atlas(config());
      state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 8
        ..rows = 2;
      pipeline = TerminalRenderPipeline(
        atlas: atlas,
        state: state,
        onImageReady: () {},
      )..configureGrid(2, 8);
    });

    tearDown(() {
      pipeline.dispose();
      atlas.dispose();
      terminal.dispose();
    });

    test('sync resolves cursor glyph and paints current frame', () {
      writeUtf8(terminal, 'A\x1b[1;1H');

      pipeline.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursorAtlasEntry, isNotNull);
      paint(pipeline);
    });

    test('bindAtlas keeps the frame pipeline configured', () {
      writeUtf8(terminal, 'A\x1b[1;1H');
      pipeline.sync(terminal, terminalDirty: true);

      final nextAtlas = Atlas(config(fontSize: 16));
      addTearDown(nextAtlas.dispose);

      pipeline.bindAtlas(nextAtlas);
      pipeline.sync(terminal, terminalDirty: false);

      expect(state.cursorAtlasEntry, isNotNull);
      paint(pipeline);
    });

    test('selection dirtying can repaint without terminal changes', () {
      writeUtf8(terminal, 'hello');
      pipeline.sync(terminal, terminalDirty: true);

      state.selection = const TerminalSelection(
        startRow: 0,
        startCol: 1,
        endRow: 0,
        endCol: 3,
      );
      pipeline.markSelectionRowsDirty(state.selection, viewportOffset: 0);

      pipeline.sync(terminal, terminalDirty: false);

      paint(pipeline);
    });

    test('highlight dirtying can repaint without terminal changes', () {
      writeUtf8(terminal, 'hello');
      pipeline.sync(terminal, terminalDirty: true);

      state.highlights = const [
        HighlightRange(startRow: 0, startCol: 1, endRow: 0, endCol: 3),
      ];
      pipeline.markHighlightRowsDirty(state.highlights, viewportOffset: 0);

      pipeline.sync(terminal, terminalDirty: false);

      paint(pipeline);
    });

    test('highlight painter fills the highlighted cells', () async {
      writeUtf8(terminal, 'hello');
      pipeline.sync(terminal, terminalDirty: true);

      state.highlights = const [
        HighlightRange(
          startRow: 0,
          startCol: 1,
          endRow: 0,
          endCol: 3,
          background: Color(0xFFFF0000),
        ),
      ];

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      pipeline.paint(canvas);
      final image = recorder.endRecording().toImageSync(
        (8 * metrics.cellWidth).round(),
        (2 * metrics.cellHeight).round(),
      );
      addTearDown(image.dispose);

      // The red highlight fill covers cols 1..2 on row 0. Sample near the
      // top edge of the cell (above the glyph baseline, so no text ink) to
      // read the fill directly: col 1 is red, col 5 (outside the range) is not.
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      int rgbAt(int x, int y) {
        final i = (y * image.width + x) * 4;
        return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      }

      const sampleY = 1;
      final insideX = (1 * metrics.cellWidth + metrics.cellWidth / 2).round();
      final outsideX = (5 * metrics.cellWidth + metrics.cellWidth / 2).round();
      expect(rgbAt(insideX, sampleY), 0xFF0000);
      expect(rgbAt(outsideX, sampleY), isNot(0xFF0000));
    });
  });
}
