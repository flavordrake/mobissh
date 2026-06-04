import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/rendering/atlas/atlas_config.dart';
import 'package:flterm/src/rendering/atlas/atlas_entry.dart';
import 'package:flterm/src/rendering/atlas/atlas_texture.dart';
import 'package:flterm/src/rendering/atlas/lanes/text_lane.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextLane', () {
    AtlasConfig config({
      CellMetrics metrics = const CellMetrics(
        cellWidth: 8,
        cellHeight: 16,
        baseline: 12,
      ),
    }) {
      return AtlasConfig(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: metrics,
        devicePixelRatio: 1.0,
      );
    }

    late TextLane lane;

    setUp(() {
      lane = TextLane(initialSize: 32, maxSize: 128)..configure(config());
    });

    tearDown(() {
      lane.dispose();
    });

    Future<({int left, int right, int width})> paintedBounds(
      Image image,
      AtlasEntry entry,
    ) async {
      final bytes = await image.toByteData();
      final data = bytes!.buffer.asUint8List();
      final imageWidth = image.width;
      final left = entry.srcLeft.floor();
      final right = entry.srcRight.ceil();
      final top = entry.srcTop.floor();
      final bottom = entry.srcBottom.ceil();
      var paintedLeft = right;
      var paintedRight = left - 1;
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          final alpha = data[(y * imageWidth + x) * 4 + 3];
          if (alpha > 0) {
            paintedLeft = x < paintedLeft ? x : paintedLeft;
            paintedRight = x > paintedRight ? x : paintedRight;
          }
        }
      }

      return (
        left: paintedLeft,
        right: paintedRight,
        width: paintedRight >= paintedLeft ? paintedRight - paintedLeft + 1 : 0,
      );
    }

    test('rasterizeText allocates a pending text entry', () {
      final entry = lane.rasterizeText('A', bold: false, italic: false);

      expect(entry.lane, AtlasEntryLane.text);
      expect(entry.srcRight, greaterThan(entry.srcLeft));
      expect(lane.hasPending, isTrue);
      expect(lane.image, isNull);
    });

    test('ensureImage creates the atlas image and clears pending text', () {
      lane.rasterizeText('A', bold: false, italic: false);

      lane.ensureImage();

      expect(lane.image, isNotNull);
      expect(lane.hasPending, isFalse);
    });

    test('rasterizeText preserves narrow glyph width in wide spans', () async {
      final lane = TextLane(initialSize: 128, maxSize: 128)
        ..configure(
          config(
            metrics: const CellMetrics(
              cellWidth: 32,
              cellHeight: 32,
              baseline: 24,
            ),
          ),
        );
      addTearDown(lane.dispose);
      final single = lane.rasterizeText('A', bold: false, italic: false);
      final wide = lane.rasterizeText('A', bold: false, italic: false, span: 2);

      lane.ensureImage();
      final image = lane.image!;
      final singleBounds = await paintedBounds(image, single);
      final wideBounds = await paintedBounds(image, wide);

      expect(wideBounds.width, lessThanOrEqualTo(singleBounds.width + 2));
    });

    test('rasterizeText centers narrow glyphs in wide spans', () async {
      final lane = TextLane(initialSize: 128, maxSize: 128)
        ..configure(
          config(
            metrics: const CellMetrics(
              cellWidth: 32,
              cellHeight: 32,
              baseline: 24,
            ),
          ),
        );
      addTearDown(lane.dispose);
      final entry = lane.rasterizeText(
        'A',
        bold: false,
        italic: false,
        span: 2,
      );

      lane.ensureImage();
      final image = lane.image!;
      final bounds = await paintedBounds(image, entry);
      final leftInset = bounds.left - entry.srcLeft.floor();
      final rightInset = entry.srcRight.ceil() - bounds.right - 1;
      final insetDelta = (leftInset - rightInset).abs();

      expect(insetDelta, lessThanOrEqualTo(2));
    });

    test('clear drops pending text and releases the image', () {
      lane.rasterizeText('A', bold: false, italic: false);
      lane.ensureImage();
      lane.rasterizeText('B', bold: false, italic: false);

      lane.clear();

      expect(lane.hasPending, isFalse);
      expect(lane.image, isNull);
    });

    test('throws when a single slot exceeds the max atlas size', () {
      final lane = TextLane(initialSize: 16, maxSize: 32)
        ..configure(
          config(
            metrics: const CellMetrics(
              cellWidth: 32,
              cellHeight: 8,
              baseline: 6,
            ),
          ),
        );
      addTearDown(lane.dispose);

      expect(
        () => lane.rasterizeText('A', bold: false, italic: false),
        throwsA(isA<AtlasFullException>()),
      );
    });

    test('throws before returning out-of-bounds entries when full', () {
      final lane = TextLane(initialSize: 16, maxSize: 32)
        ..configure(
          config(
            metrics: const CellMetrics(
              cellWidth: 8,
              cellHeight: 8,
              baseline: 6,
            ),
          ),
        );
      addTearDown(lane.dispose);

      var added = 0;
      AtlasFullException? full;
      for (var i = 0; i < 64; i++) {
        try {
          final entry = lane.rasterizeText(
            String.fromCharCode(0x41 + i),
            bold: false,
            italic: false,
          );
          expect(entry.srcRight, lessThanOrEqualTo(32));
          expect(entry.srcBottom, lessThanOrEqualTo(32));
          added++;
        } on AtlasFullException catch (error) {
          full = error;
          break;
        }
      }

      expect(added, greaterThan(0));
      expect(full, isNotNull);
    });
  });
}
