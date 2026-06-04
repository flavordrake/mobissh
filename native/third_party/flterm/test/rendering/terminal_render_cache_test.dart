import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering/atlas/atlas_config.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TerminalRenderCache', () {
    AtlasConfig key({double fontSize = 14}) {
      return AtlasConfig(
        fontSize: fontSize,
        fontWeight: FontWeight.normal,
        fontFamily: 'monospace',
        fontFamilyFallback: const [],
        metrics: const CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12),
        devicePixelRatio: 1.0,
      );
    }

    test('shares atlas for matching keys', () {
      final cache = TerminalRenderCache();
      addTearDown(cache.dispose);

      final first = cache.acquireAtlas(key());
      final second = cache.acquireAtlas(key());
      addTearDown(second.release);
      addTearDown(first.release);

      expect(second.atlas, same(first.atlas));
    });

    test('keeps atlas alive until the last handle is released', () {
      final cache = TerminalRenderCache();
      addTearDown(cache.dispose);

      final first = cache.acquireAtlas(key());
      final second = cache.acquireAtlas(key());
      final atlas = first.atlas;

      first.release();
      expect(atlas.textImage, isNotNull);

      second.release();
      expect(atlas.textImage, isNull);
    });

    test('does not share atlas across font-affecting keys', () {
      final cache = TerminalRenderCache();
      addTearDown(cache.dispose);

      final first = cache.acquireAtlas(key());
      final second = cache.acquireAtlas(key(fontSize: 16));
      addTearDown(second.release);
      addTearDown(first.release);

      expect(second.atlas, isNot(same(first.atlas)));
    });
  });
}
