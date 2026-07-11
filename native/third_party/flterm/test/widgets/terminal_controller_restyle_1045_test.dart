@Tags(['ffi'])
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1045: the detection wash renders through the fork's highlight paint pass,
/// so the CONTROLLER must style each match's ranges per ANCHOR (verified
/// alpha, Detection Lab live-apply) and honor SUPPRESSION (#990/#995: a
/// suppressed anchor paints NOTHING) — a static per-pattern style cannot.
/// [TerminalController.detectionHighlightStyleOf] is that seam: it runs when
/// matches are baked into `highlights`, and
/// [TerminalController.restyleDetectionHighlights] re-bakes WITHOUT a rescan
/// when app-side style state changes (a verification lands, a lab slider
/// moves, an exception is filed).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('detectionHighlightStyleOf (#1045)', () {
    late TerminalControllerImpl controller;

    setUp(() => controller = TerminalControllerImpl());
    tearDown(() => controller.dispose());

    Future<void> writeAndScan(String text) async {
      controller.write(Uint8List.fromList(text.codeUnits));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    test('resolver output styles the baked highlight ranges', () async {
      const wash = Color(0x4433AA55);
      controller.detectionHighlightStyleOf =
          (match) => const HighlightStyle(background: wash, capsule: true);
      // The pattern itself registers with the EMPTY style (#864) — the
      // resolver, not the registration, owns the fill.
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('see https://example.com here\r\n');

      expect(controller.highlights, isNotEmpty);
      for (final range in controller.highlights) {
        expect(range.background, wash);
        expect(range.capsule, isTrue);
      }
      // A single-row match is a full capsule: both caps on its one range.
      final range = controller.highlights.single;
      expect(range.capsuleStart, isTrue);
      expect(range.capsuleEnd, isTrue);
    });

    test('a null resolver result SUPPRESSES the fill but keeps the anchor',
        () async {
      controller.detectionHighlightStyleOf = (match) => null;
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('go https://foo.io now\r\n');

      expect(controller.highlights, isEmpty,
          reason: 'suppressed anchors paint NOTHING');
      // Hit-testing and the gutter still see the match — suppression gates
      // only the painted fill, exactly like the retired widget-layer gate.
      expect(controller.anchors, isNotEmpty);
      expect(controller.matchAt(row: 0, col: 5), isNotNull);
    });

    test('restyleDetectionHighlights re-bakes without a rescan', () async {
      var wash = const Color(0x44112233);
      var suppressed = false;
      controller.detectionHighlightStyleOf = (match) => suppressed
          ? null
          : HighlightStyle(background: wash, capsule: true);
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('see https://example.com here\r\n');
      expect(controller.highlights.single.background, wash);

      // A style change (Detection Lab live-apply / verified alpha) re-bakes
      // SYNCHRONOUSLY — no debounce wait, no rescan.
      wash = const Color(0x66AA5533);
      controller.restyleDetectionHighlights();
      expect(controller.highlights.single.background, wash);

      // A suppression change (#995 exception filed) clears the fill.
      suppressed = true;
      controller.restyleDetectionHighlights();
      expect(controller.highlights, isEmpty);
      expect(controller.anchors, isNotEmpty);

      // And back.
      suppressed = false;
      controller.restyleDetectionHighlights();
      expect(controller.highlights.single.background, wash);
    });

    test('restyle is a NO-OP (no notify) when the bake is unchanged',
        () async {
      controller.detectionHighlightStyleOf = (match) =>
          const HighlightStyle(background: Color(0x4433AA55), capsule: true);
      controller.registerTextPattern(TextPattern.url());
      await writeAndScan('see https://example.com here\r\n');

      var notifies = 0;
      controller.addListener(() => notifies++);
      controller.restyleDetectionHighlights();
      expect(notifies, 0,
          reason: 'an unchanged restyle must not churn listeners — the app '
              'calls it on every build');
    });

    test('a WRAPPED match rounds caps ONLY on the true first/last rows',
        () async {
      controller.detectionHighlightStyleOf = (match) =>
          const HighlightStyle(background: Color(0x4433AA55), capsule: true);
      controller.registerTextPattern(TextPattern.url());
      // Default grid is 80 cols; a ~150-char URL soft-wraps onto row 1.
      final url = 'https://example.com/${'a' * 130}';
      await writeAndScan('$url\r\n');

      final ranges = controller.highlights;
      expect(ranges.length, greaterThanOrEqualTo(2),
          reason: 'the wrapped URL must occupy multiple per-row ranges');
      expect(ranges.first.capsuleStart, isTrue);
      expect(ranges.first.capsuleEnd, isFalse);
      expect(ranges.last.capsuleStart, isFalse);
      expect(ranges.last.capsuleEnd, isTrue);
      for (final middle in ranges.sublist(1, ranges.length - 1)) {
        expect(middle.capsuleStart, isFalse);
        expect(middle.capsuleEnd, isFalse);
        expect(middle.capsule, isTrue);
      }
    });

    test('with NO resolver the pattern style bakes as before (fallback)',
        () async {
      const patternFill = Color(0x335B9BD5);
      controller.registerTextPattern(
        TextPattern.url(
          style: const HighlightStyle(background: patternFill),
        ),
      );
      await writeAndScan('see https://example.com here\r\n');

      expect(controller.highlights, isNotEmpty);
      expect(controller.highlights.single.background, patternFill);
      expect(controller.highlights.single.capsule, isFalse);
    });
  });
}
