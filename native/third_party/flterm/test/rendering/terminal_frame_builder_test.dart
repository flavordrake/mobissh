@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/foundation/dynamic_color.dart';
import 'package:flterm/src/foundation/terminal_selection.dart';
import 'package:flterm/src/foundation/terminal_theme.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/atlas/sprite_buffer.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/terminal_frame_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('TerminalFrameBuilder', () {
    const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

    AtlasConfig config() {
      return AtlasConfig(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: metrics,
        devicePixelRatio: 1.0,
      );
    }

    void writeUtf8(Terminal terminal, String text) {
      terminal.write(Uint8List.fromList(utf8.encode(text)));
    }

    List<double> xPositions(AtlasSprites sprites) {
      final transforms = sprites.sealedTransforms;
      return List.generate(sprites.count, (index) => transforms[index * 4 + 2]);
    }

    String entryRectKey(AtlasEntry entry) {
      return [
        entry.srcLeft,
        entry.srcTop,
        entry.srcRight,
        entry.srcBottom,
      ].join(',');
    }

    String spriteRectKey(AtlasSprites sprites, int index) {
      final rects = sprites.sealedRects;
      final offset = index * 4;
      return [
        rects[offset],
        rects[offset + 1],
        rects[offset + 2],
        rects[offset + 3],
      ].join(',');
    }

    List<String> wideGlyphs(
      Atlas atlas,
      AtlasSprites sprites,
      Iterable<String> glyphs,
    ) {
      final glyphByRect = <String, String>{};
      for (final glyph in glyphs) {
        final entry = atlas.addCodepoint(
          glyph.runes.single,
          bold: false,
          italic: false,
          span: 2,
        );
        glyphByRect[entryRectKey(entry)] = glyph;
      }
      return [
        for (var i = 0; i < sprites.count; i++)
          glyphByRect[spriteRectKey(sprites, i)]!,
      ];
    }

    ({
      Terminal terminal,
      Atlas atlas,
      SpriteBuffer sprites,
      TerminalPaintState state,
      TerminalFrameBuilder builder,
    })
    createFrame({required int cols, required int rows}) {
      final terminal = Terminal(cols: cols, rows: rows);
      final atlas = Atlas(config());
      final sprites = SpriteBuffer();
      final state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = cols
        ..rows = rows;
      final builder = TerminalFrameBuilder(atlas, sprites, state)
        ..configure(rows, cols);
      addTearDown(() {
        builder.dispose();
        sprites.dispose();
        atlas.dispose();
        terminal.dispose();
      });
      return (
        terminal: terminal,
        atlas: atlas,
        sprites: sprites,
        state: state,
        builder: builder,
      );
    }

    late Terminal terminal;
    late Atlas atlas;
    late SpriteBuffer sprites;
    late TerminalPaintState state;
    late TerminalFrameBuilder builder;

    setUp(() {
      terminal = Terminal(cols: 8, rows: 2);
      atlas = Atlas(config());
      sprites = SpriteBuffer();
      state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 8
        ..rows = 2;
      builder = TerminalFrameBuilder(atlas, sprites, state)..configure(2, 8);
    });

    tearDown(() {
      builder.dispose();
      sprites.dispose();
      atlas.dispose();
      terminal.dispose();
    });

    test('sync emits text, sprite, and emoji channels', () {
      writeUtf8(terminal, 'A\u2500\u{1F600}');

      builder.sync(terminal, terminalDirty: true);

      expect(sprites.regular.count, greaterThan(0));
      expect(sprites.sprite.count, greaterThan(0));
      expect(sprites.emoji.count, greaterThan(0));
      expect(atlas.spriteImage, isNotNull);
      expect(atlas.emojiImage, isNotNull);
    });

    test('sync emits operator ligatures without adding text atlas entries', () {
      final initialCacheSize = atlas.cacheSize;
      writeUtf8(terminal, '=> !=');

      builder.sync(terminal, terminalDirty: true);

      expect(sprites.shaped.count, 2);
      expect(atlas.cacheSize, initialCacheSize);
    });

    test('sync chunks long operator runs without adding atlas entries', () {
      final localTerminal = Terminal(cols: 260, rows: 1);
      final localAtlas = Atlas(config());
      final localSprites = SpriteBuffer();
      final localState = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = 260
        ..rows = 1;
      final localBuilder = TerminalFrameBuilder(
        localAtlas,
        localSprites,
        localState,
      )..configure(1, 260);
      addTearDown(() {
        localBuilder.dispose();
        localSprites.dispose();
        localAtlas.dispose();
        localTerminal.dispose();
      });
      final initialCacheSize = localAtlas.cacheSize;
      writeUtf8(localTerminal, List.filled(260, r'$').join());

      localBuilder.sync(localTerminal, terminalDirty: true);

      expect(localSprites.shaped.count, 2);
      expect(localAtlas.cacheSize, initialCacheSize);
    });

    test('sync resolves palette colors from render state colors', () {
      terminal.palette = [
        for (var i = 0; i < 256; i++)
          i == 1 ? const RgbColor(1, 2, 3) : const RgbColor(0, 0, 0),
      ];
      writeUtf8(terminal, '\x1b[31mA');

      builder.sync(terminal, terminalDirty: true);

      expect(sprites.regular.sealedColors.single, 0xFF010203.toSigned(32));
    });

    test('sync updates terminal background after OSC 11', () {
      terminal.foreground = const RgbColor(255, 255, 255);
      terminal.background = const RgbColor(0, 0, 0);
      builder.sync(terminal, terminalDirty: true);
      writeUtf8(terminal, '\x1b]11;rgb:1e/20/24\x1b\\');

      builder.sync(terminal, terminalDirty: true);

      expect(state.terminalBackgroundArgb, 0xFF1E2024);
    });

    test('sync rebuilds retained text colors after OSC 10', () {
      terminal.foreground = const RgbColor(255, 255, 255);
      terminal.background = const RgbColor(0, 0, 0);
      writeUtf8(terminal, 'A\r\nB');
      builder.sync(terminal, terminalDirty: true);
      writeUtf8(terminal, '\x1b]10;rgb:01/02/03\x1b\\');

      builder.sync(terminal, terminalDirty: true);

      expect(sprites.regular.sealedColors, [
        0xFF010203.toSigned(32),
        0xFF010203.toSigned(32),
      ]);
    });

    test('sync emits erase backgrounds after resize', () {
      final frame = createFrame(cols: 8, rows: 2);
      writeUtf8(frame.terminal, '\x1b[2;2H\x1b[48;2;30;32;36m\x1b[K\x1b[0m');
      frame.builder.sync(frame.terminal, terminalDirty: true);
      frame.terminal.resize(cols: 10, rows: 2);
      frame.state
        ..cols = 10
        ..rows = 2;
      frame.builder
        ..configure(2, 10)
        ..markAllRowsDirty();

      frame.builder.sync(frame.terminal, terminalDirty: true);

      expect(frame.sprites.background.count, greaterThan(0));
    });

    test('sync resolves cursor dynamic colors from render state colors', () {
      state.updateTheme(
        TerminalTheme.dark().copyWith(
          cursor: const CursorTheme(color: DynamicColor.cellForeground()),
        ),
      );
      terminal.palette = [
        for (var i = 0; i < 256; i++)
          i == 1 ? const RgbColor(1, 2, 3) : const RgbColor(0, 0, 0),
      ];
      writeUtf8(terminal, '\x1b[31mA\x1b[1;1H');

      builder.sync(terminal, terminalDirty: true);

      expect(state.cursorColorArgb, 0xFF010203);
    });

    test('sync resolves underline colors from render state colors', () {
      terminal.palette = [
        for (var i = 0; i < 256; i++)
          i == 1 ? const RgbColor(1, 2, 3) : const RgbColor(0, 0, 0),
      ];
      writeUtf8(terminal, '\x1b[4;58;5;1mA');

      builder.sync(terminal, terminalDirty: true);

      expect(sprites.underline.sealedColors.single, 0xFF010203.toSigned(32));
    });

    test(
      'sync emits selection background without terminal access in paint',
      () {
        writeUtf8(terminal, 'hello');
        state.selection = const TerminalSelection(
          startRow: 0,
          startCol: 1,
          endRow: 0,
          endCol: 3,
        );

        builder.sync(terminal, terminalDirty: true);

        expect(sprites.background.count, greaterThan(0));
      },
    );

    test('sync resolves block cursor glyph from cached frame state', () {
      writeUtf8(terminal, 'A\x1b[1;1H');
      builder.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursor.col, 0);
      expect(state.cursorAtlasEntry, isNotNull);
    });

    test('sync skips cursor glyph on empty cells', () {
      builder.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursorAtlasEntry, isNull);
    });

    test('sync skips cursor glyph when the terminal is unfocused', () {
      state.cursorFocused = false;
      writeUtf8(terminal, 'A\x1b[1;1H');

      builder.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursorAtlasEntry, isNull);
    });

    test('sync skips cursor glyph for non-block cursors', () {
      state.updateTheme(
        TerminalTheme.dark().copyWith(
          cursor: const CursorTheme(shape: CursorShape.underline),
        ),
      );
      writeUtf8(terminal, 'A\x1b[1;1H');

      builder.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursor.shape, CursorShape.underline);
      expect(state.cursorAtlasEntry, isNull);
    });

    test('sync skips cursor glyph on invisible text', () {
      writeUtf8(terminal, '\x1b[8mA\x1b[1;1H');

      builder.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursorAtlasEntry, isNull);
    });

    test('sync skips cursor glyph on blink-hidden text', () {
      state.blinkVisible = false;
      writeUtf8(terminal, '\x1b[5mA\x1b[1;1H');

      builder.sync(terminal, terminalDirty: true);

      expect(state.cursor.visible, isTrue);
      expect(state.cursorAtlasEntry, isNull);
    });

    test('sync replaces only the active preedit cell range', () {
      writeUtf8(terminal, 'abcdef\x1b[1;3H');

      builder.sync(terminal, terminalDirty: true, preeditText: '日');

      expect(xPositions(sprites.regular), [0.0, 8.0, 32.0, 40.0]);
      expect(xPositions(sprites.wide), [16.0]);
    });

    test('sync emits a continuous preedit underline', () {
      writeUtf8(terminal, 'abcdef\x1b[1;3H');

      builder.sync(terminal, terminalDirty: true, preeditText: '日');

      expect(sprites.underline.count, 0);
      expect(sprites.decoration.count, 1);
    });

    test('sync shifts wide preedit left at the row edge', () {
      writeUtf8(terminal, 'abcdefgh\x1b[1;8H');

      builder.sync(terminal, terminalDirty: true, preeditText: '日');

      expect(xPositions(sprites.wide), [48.0]);
      expect(sprites.decoration.count, 1);
    });

    test('sync keeps visible tail when preedit is wider than the row', () {
      final frame = createFrame(cols: 6, rows: 1);
      writeUtf8(frame.terminal, 'ab\x1b[1;3H');

      frame.builder.sync(
        frame.terminal,
        terminalDirty: true,
        preeditText: '一二三四五',
      );

      expect(xPositions(frame.sprites.wide), [0.0, 16.0, 32.0]);
      expect(
        wideGlyphs(frame.atlas, frame.sprites.wide, ['一', '二', '三', '四', '五']),
        ['三', '四', '五'],
      );
    });

    test('sync keeps the visible tail when clipping starts at column zero', () {
      final frame = createFrame(cols: 4, rows: 1);

      frame.builder.sync(
        frame.terminal,
        terminalDirty: true,
        preeditText: '一二三四五',
      );

      expect(xPositions(frame.sprites.wide), [0.0, 16.0]);
      expect(
        wideGlyphs(frame.atlas, frame.sprites.wide, ['一', '二', '三', '四', '五']),
        ['四', '五'],
      );
    });

    test('sync preserves cells after a partial wide preedit slot', () {
      final frame = createFrame(cols: 7, rows: 1);
      writeUtf8(frame.terminal, 'abcdefg\x1b[1;1H');

      frame.builder.sync(
        frame.terminal,
        terminalDirty: true,
        preeditText: '一二三四',
      );

      expect(xPositions(frame.sprites.regular), [48.0]);
      expect(xPositions(frame.sprites.wide), [0.0, 16.0, 32.0]);
    });

    test('sync suppresses wide cell that overlaps preedit range', () {
      final frame = createFrame(cols: 5, rows: 1);
      writeUtf8(frame.terminal, 'ab日x\x1b[1;5H');

      frame.builder.sync(frame.terminal, terminalDirty: true, preeditText: '你');

      expect(xPositions(frame.sprites.wide), [24.0]);
    });

    test('sync clears preedit when text becomes empty', () {
      writeUtf8(terminal, 'abcdef\x1b[1;3H');
      builder.sync(terminal, terminalDirty: true, preeditText: '日');

      builder.sync(terminal, terminalDirty: false);

      expect(state.preeditActive, isFalse);
      expect(xPositions(sprites.regular), [0.0, 8.0, 16.0, 24.0, 32.0, 40.0]);
    });

    test('sync ignores zero-width preedit text', () {
      writeUtf8(terminal, 'abcdef\x1b[1;3H');

      builder.sync(terminal, terminalDirty: true, preeditText: '\u200B');

      expect(state.preeditActive, isFalse);
    });
  });
}
