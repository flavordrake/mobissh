@Tags(['ffi', 'golden'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering/kitty_image_cache.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/painters/kitty_graphics_painter.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:libghostty/libghostty.dart'
    show DecodedImage, KittyGraphics, LibGhostty, Terminal;

void main() {
  group('KittyGraphicsPainter golden', () {
    DecodedImage? decodePng(Uint8List bytes) {
      final decoded = img.decodePng(bytes);
      if (decoded == null) return null;
      final rgba = decoded.convert(format: img.Format.uint8, numChannels: 4);
      return (
        width: rgba.width,
        height: rgba.height,
        rgba: Uint8List.fromList(rgba.toUint8List()),
      );
    }

    Future<ui.Image> imageFromRgba(Uint8List rgba, int width, int height) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    }

    Uint8List loadFixture(String name) {
      final path = [
        Directory.current.path,
        'test',
        'fixtures',
        'kitty_graphics',
        name,
      ].join(Platform.pathSeparator);
      return File(path).readAsBytesSync();
    }

    Future<ui.Image> paint({
      required int width,
      required int height,
      required void Function(Canvas canvas) draw,
    }) {
      final recorder = ui.PictureRecorder();
      final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      final canvas = Canvas(recorder, rect)
        ..drawRect(rect, Paint()..color = const Color(0xff000000));
      draw(canvas);
      return recorder.endRecording().toImage(width, height);
    }

    Uint8List quadrantsRgba() {
      const colors = <List<int>>[
        [0xff, 0x00, 0x00, 0xff],
        [0x00, 0xff, 0x00, 0xff],
        [0x00, 0x00, 0xff, 0xff],
        [0xff, 0xff, 0x00, 0xff],
      ];
      final out = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final quadrant = (y < 2 ? 0 : 2) + (x < 2 ? 0 : 1);
          final color = colors[quadrant];
          final offset = (y * 4 + x) * 4;
          out.setRange(offset, offset + 4, color);
        }
      }
      return out;
    }

    TerminalPaintState stateFor({required int cols, required int rows}) {
      return TerminalPaintState(
          TerminalTheme.dark(),
          const CellMetrics(cellWidth: 1, cellHeight: 1, baseline: 1),
        )
        ..cols = cols
        ..rows = rows;
    }

    testWidgets('draws a single placement', (tester) async {
      late ui.Image captured;
      await tester.runAsync(() async {
        final cache = KittyImageCache(onImageReady: () {});
        addTearDown(cache.dispose);
        cache.putReady(1, await imageFromRgba(quadrantsRgba(), 4, 4));

        const snapshots = <KittyPlacementSnapshot>[
          KittyPlacementSnapshot(
            imageId: 1,
            dst: Rect.fromLTWH(8, 8, 64, 64),
            src: Rect.fromLTWH(0, 0, 4, 4),
            z: 0,
          ),
        ];
        final painter = KittyGraphicsPainter(
          state: stateFor(cols: 80, rows: 80),
          cache: cache,
          snapshots: snapshots,
        );

        captured = await paint(width: 80, height: 80, draw: painter.paint);
      });
      await expectLater(
        captured,
        matchesGoldenFile('goldens/kitty_single_placement.png'),
      );
    });

    testWidgets('separates below and above layers', (tester) async {
      late ui.Image captured;
      await tester.runAsync(() async {
        final cache = KittyImageCache(onImageReady: () {});
        addTearDown(cache.dispose);
        cache.putReady(1, await imageFromRgba(quadrantsRgba(), 4, 4));
        cache.putReady(
          2,
          await imageFromRgba(
            Uint8List.fromList([0x00, 0xff, 0xff, 0xff]),
            1,
            1,
          ),
        );

        const belowSnapshots = <KittyPlacementSnapshot>[
          KittyPlacementSnapshot(
            imageId: 1,
            dst: Rect.fromLTWH(0, 0, 80, 80),
            src: Rect.fromLTWH(0, 0, 4, 4),
            z: -1,
          ),
        ];
        const aboveSnapshots = <KittyPlacementSnapshot>[
          KittyPlacementSnapshot(
            imageId: 2,
            dst: Rect.fromLTWH(40, 0, 40, 40),
            src: Rect.fromLTWH(0, 0, 1, 1),
            z: 0,
          ),
        ];

        final state = stateFor(cols: 80, rows: 80);
        final below = KittyGraphicsPainter(
          state: state,
          cache: cache,
          snapshots: belowSnapshots,
        );
        final above = KittyGraphicsPainter(
          state: state,
          cache: cache,
          snapshots: aboveSnapshots,
        );

        captured = await paint(
          width: 80,
          height: 80,
          draw: (canvas) {
            below.paint(canvas);
            above.paint(canvas);
          },
        );
      });
      await expectLater(
        captured,
        matchesGoldenFile('goldens/kitty_z_layers.png'),
      );
    });

    testWidgets('routes a PNG through the full pipeline', (tester) async {
      late ui.Image captured;
      await tester.runAsync(() async {
        LibGhostty.setPngDecoder(decodePng);
        addTearDown(LibGhostty.clearPngDecoder);

        final terminal = Terminal(cols: 80, rows: 24)
          ..kittyImageStorageLimit = 1 << 20;
        addTearDown(terminal.dispose);

        final payload = base64Encode(loadFixture('test_image.png'));
        terminal.write(
          Uint8List.fromList('\x1b_Gf=100,a=t,i=1;$payload\x1b\\'.codeUnits),
        );

        final image = KittyGraphics.of(terminal)!.image(1)!;
        expect(image.width, 64);
        expect(image.height, 64);

        final cache = KittyImageCache(onImageReady: () {});
        addTearDown(cache.dispose);
        cache.putReady(
          image.id,
          await imageFromRgba(image.pixelData, image.width, image.height),
        );

        final snapshots = [
          KittyPlacementSnapshot(
            imageId: image.id,
            dst: const Rect.fromLTWH(0, 0, 64, 64),
            src: const Rect.fromLTWH(0, 0, 64, 64),
            z: 0,
          ),
        ];
        final painter = KittyGraphicsPainter(
          state: stateFor(cols: 64, rows: 64),
          cache: cache,
          snapshots: snapshots,
        );

        captured = await paint(width: 64, height: 64, draw: painter.paint);
      });
      await expectLater(
        captured,
        matchesGoldenFile('goldens/kitty_png_pipeline.png'),
      );
    });
  });
}
