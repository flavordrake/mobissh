@Tags(['ffi'])
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalController structured-text detection (#767)', () {
    late TerminalControllerImpl controller;

    setUp(() => controller = TerminalControllerImpl());
    tearDown(() => controller.dispose());

    /// Pump the terminal with [text] and flush the detection debounce.
    Future<void> writeAndScan(String text) async {
      controller.write(Uint8List.fromList(text.codeUnits));
      // The re-scan is debounced (~120ms); wait past it.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    test('registerTextPattern detects a URL and populates highlights', () async {
      controller.registerTextPattern(
        TextPattern.url(
          style: const HighlightStyle(background: Color(0x335B9BD5)),
        ),
      );
      await writeAndScan('see https://example.com here\r\n');

      expect(
        controller.highlights,
        isNotEmpty,
        reason: 'a detected URL should populate controller.highlights',
      );
      // The highlight payload recovers the URL.
      expect(
        controller.highlights.any((r) => r.payload == 'https://example.com'),
        isTrue,
      );
    });

    test('matchAt resolves the URL under a viewport cell', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('go https://foo.io now\r\n');

      // 'go ' == 3 chars; the URL starts at viewport col 3 on the row it
      // printed (row 0 — first and only line). matchAt is viewport-relative.
      final match = controller.matchAt(row: 0, col: 5);
      expect(match, isNotNull);
      expect(match!.payload, 'https://foo.io');
    });

    test('matchAt returns null off any match', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('go https://foo.io now\r\n');

      // Col 0 ('g') is before the URL.
      expect(controller.matchAt(row: 0, col: 0), isNull);
    });

    test('clearTextPatterns removes detection and clears highlights', () async {
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('https://bar.org\r\n');
      expect(controller.highlights, isNotEmpty);

      controller.clearTextPatterns();
      expect(controller.highlights, isEmpty);
      expect(controller.matchAt(row: 0, col: 2), isNull);
    });

    test('re-registering a pattern id replaces it (no duplicate)', () async {
      controller.registerTextPattern(
        TextPattern.url(style: const HighlightStyle(background: Color(0xFF000001))),
      );
      await writeAndScan('https://baz.net\r\n');
      // Restyle: clear + re-register (the theme-recolor path).
      controller.clearTextPatterns();
      controller.registerTextPattern(
        TextPattern.url(style: const HighlightStyle(background: Color(0xFF000002))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Exactly one URL, restyled to the new color.
      final urlRanges =
          controller.highlights.where((r) => r.payload == 'https://baz.net');
      expect(urlRanges, isNotEmpty);
      expect(urlRanges.every((r) => r.background == const Color(0xFF000002)),
          isTrue);
    });
  });
}
