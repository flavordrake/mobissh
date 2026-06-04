import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flterm/src/rendering/atlas/atlas_config.dart';
import 'package:flterm/src/rendering/atlas/atlas_entry.dart';
import 'package:flterm/src/rendering/atlas/lanes/decoration_lane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  group('DecorationLane', () {
    AtlasConfig config() {
      return AtlasConfig(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: const CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12),
        devicePixelRatio: 1.0,
      );
    }

    late DecorationLane lane;

    setUp(() {
      lane = DecorationLane(initialSize: 32, maxSize: 128)..configure(config());
    });

    tearDown(() {
      lane.dispose();
    });

    test('rasterizeDecoration allocates a pending decoration entry', () {
      final entry = lane.rasterizeDecoration(UnderlineStyle.single);

      expect(entry.lane, AtlasEntryLane.decoration);
      expect(entry.srcRight, greaterThan(entry.srcLeft));
      expect(lane.hasPending, isTrue);
      expect(lane.image, isNull);
    });

    test(
      'ensureImage creates the atlas image and clears pending decorations',
      () {
        lane.rasterizeDecoration(UnderlineStyle.single);

        lane.ensureImage();

        expect(lane.image, isNotNull);
        expect(lane.hasPending, isFalse);
      },
    );
  });
}
