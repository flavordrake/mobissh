@Tags(['ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/rendering/atlas/atlas_config.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

import 'helpers/font_loader.dart';

void main() {
  setUpAll(loadBundledFonts);

  const altMetrics = CellMetrics(cellWidth: 10, cellHeight: 20, baseline: 15);
  const defaultCols = 25;
  const defaultMetrics = CellMetrics(
    cellWidth: 8,
    cellHeight: 16,
    baseline: 12,
  );
  const defaultRows = 5;

  TerminalRenderCache createRenderCache() {
    final cache = TerminalRenderCache();
    addTearDown(cache.dispose);
    return cache;
  }

  Widget wrap(
    Terminal terminal, {
    TerminalTheme? theme,
    CellMetrics metrics = defaultMetrics,
    TerminalSelection? selection,
    double? maxWidth,
    double? maxHeight,
    bool focused = true,
    bool blinkVisible = true,
    OnResize? onResize,
    TerminalRenderCache? renderCache,
  }) {
    renderCache ??= createRenderCache();
    final width = maxWidth ?? defaultCols * metrics.cellWidth;
    final height = maxHeight ?? defaultRows * metrics.cellHeight;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: height),
          child: TerminalRenderer(
            terminal: terminal,
            theme: theme ?? TerminalTheme.dark(),
            metrics: metrics,
            offset: ViewportOffset.zero(),
            renderCache: renderCache,
            renderObserver: _TestRenderObserver(
              selection: selection,
              hasFocus: focused,
            ),
            blinkVisible: blinkVisible,
            onResize: onResize,
          ),
        ),
      ),
    );
  }

  group('TerminalRenderBox layout', () {
    late Terminal terminal;

    setUp(() => terminal = Terminal(cols: defaultCols, rows: defaultRows));

    tearDown(() => terminal.dispose());

    testWidgets('snaps width to whole-cell multiples', (tester) async {
      await tester.pumpWidget(
        wrap(
          terminal,
          maxWidth: 163.7,
          maxHeight: defaultRows * defaultMetrics.cellHeight,
        ),
      );
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(box.size.width, 160.0);
    });

    testWidgets('snaps height to whole-cell multiples', (tester) async {
      await tester.pumpWidget(
        wrap(
          terminal,
          maxWidth: defaultCols * defaultMetrics.cellWidth,
          maxHeight: 85.3,
        ),
      );
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(box.size.height, 80.0);
    });

    testWidgets('metrics change triggers layout', (tester) async {
      await tester.pumpWidget(wrap(terminal));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      final sizeBefore = box.size;

      await tester.pumpWidget(wrap(terminal, metrics: altMetrics));
      expect(box.size, isNot(equals(sizeBefore)));
    });

    testWidgets('onResize fires when grid dimensions change', (tester) async {
      int? reportedCols;
      int? reportedRows;
      await tester.pumpWidget(
        wrap(
          terminal,
          onResize: (cols, rows) {
            reportedCols = cols;
            reportedRows = rows;
          },
        ),
      );
      expect(reportedCols, defaultCols);
      expect(reportedRows, defaultRows);
    });

    testWidgets('theme change triggers layout', (tester) async {
      final renderCache = _TrackingRenderCache();
      addTearDown(renderCache.dispose);
      await tester.pumpWidget(wrap(terminal, renderCache: renderCache));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      expect(box.theme, TerminalTheme.dark());
      final acquisitionsBefore = renderCache.acquiredKeys.length;

      final light = TerminalTheme.light();
      await tester.pumpWidget(
        wrap(terminal, theme: light, renderCache: renderCache),
      );
      expect(box.theme, light);
      expect(renderCache.acquiredKeys, hasLength(acquisitionsBefore));
    });

    testWidgets('font theme change reacquires atlas', (tester) async {
      final renderCache = _TrackingRenderCache();
      addTearDown(renderCache.dispose);
      await tester.pumpWidget(wrap(terminal, renderCache: renderCache));
      final keyBefore = renderCache.acquiredKeys.last;

      final larger = TerminalTheme.dark().copyWith(fontSize: 18);
      await tester.pumpWidget(
        wrap(terminal, theme: larger, renderCache: renderCache),
      );
      await tester.pump();

      expect(renderCache.acquiredKeys.last, isNot(keyBefore));
    });

    testWidgets('selection change does not trigger layout', (tester) async {
      await tester.pumpWidget(wrap(terminal));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );
      final sizeBefore = box.size;

      await tester.pumpWidget(
        wrap(
          terminal,
          selection: const TerminalSelection(
            startRow: 0,
            startCol: 0,
            endRow: 0,
            endCol: 5,
          ),
        ),
      );
      expect(box.size, equals(sizeBefore));
    });
  });

  group('TerminalRenderBox blink visibility', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(cols: defaultCols, rows: defaultRows);
      terminal.write(Uint8List.fromList(utf8.encode('hello')));
    });

    tearDown(() => terminal.dispose());

    testWidgets('blinkVisible toggles cursor visibility', (tester) async {
      await tester.pumpWidget(wrap(terminal));
      final box = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );

      expect(box.blinkVisible, isTrue);

      await tester.pumpWidget(wrap(terminal, blinkVisible: false));
      expect(box.blinkVisible, isFalse);

      await tester.pumpWidget(wrap(terminal));
      expect(box.blinkVisible, isTrue);
    });

    testWidgets('unfocused terminal stays mounted', (tester) async {
      await tester.pumpWidget(wrap(terminal, focused: false));
      expect(find.byType(TerminalRenderer), findsOneWidget);
    });
  });
}

class _TrackingRenderCache extends TerminalRenderCache {
  final acquiredKeys = <AtlasConfig>[];

  @override
  TerminalAtlasHandle acquireAtlas(AtlasConfig config) {
    acquiredKeys.add(config);
    return super.acquireAtlas(config);
  }
}

class _TestRenderObserver implements TerminalRenderObserver {
  @override
  final TerminalSelection? selection;

  @override
  final bool hasFocus;

  const _TestRenderObserver({this.selection, this.hasFocus = true});

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
