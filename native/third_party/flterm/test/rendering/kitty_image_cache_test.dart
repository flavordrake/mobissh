import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KittyImageCache', () {
    Future<ui.Image> testImage() {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0xff, 0xff, 0xff, 0xff]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    }

    test('dispose clears ready entries and is idempotent', () async {
      final cache = KittyImageCache(onImageReady: () {});
      addTearDown(cache.dispose);
      final image = await testImage();

      cache.putReady(1, image);
      expect(cache.lookupById(1), isA<KittyImageReady>());

      cache.dispose();
      cache.dispose();

      expect(cache.lookupById(1), isNull);
    });
  });
}
