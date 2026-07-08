// #998 slice A — matchAt tier preference: a tap on a cell covered by BOTH a
// span-tier match (url/path) and a block-tier match (command line) resolves
// the SPAN match — inline taps never route to the containing command block —
// while the block match stays resolvable via `matchAt(tier: TextTier.block)`.
//
// Before this slice matchAt returned the LAST containing match (registration-
// order accident), so a block pattern registered after the url pattern would
// steal every inline tap.

@Tags(['ffi'])
library;

import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('matchAt tier preference (#998 slice A)', () {
    late TerminalControllerImpl controller;

    setUp(() {
      controller = TerminalControllerImpl();
      // url FIRST, block SECOND — under the old last-wins rule the block match
      // would shadow the url at every covered cell.
      controller.registerTextPattern(TextPattern.url());
      controller.registerTextPattern(
        TextPattern(
          id: 'cmd',
          regex: RegExp(r'^\$ (.+)$'),
          tier: TextTier.block,
          rangeGroup: 1,
        ),
      );
    });
    tearDown(() => controller.dispose());

    /// Pump the terminal with [text] and flush the detection debounce.
    Future<void> writeAndScan(String text) async {
      controller.write(Uint8List.fromList(text.codeUnits));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    test('a cell covered by both tiers resolves the SPAN match', () async {
      await writeAndScan('\$ curl https://foo.io now\r\n');

      // '$ curl ' == 7 chars; the URL covers cols 7..20. Col 8 sits inside
      // BOTH the url span and the command block.
      final match = controller.matchAt(row: 0, col: 8);
      expect(match, isNotNull);
      expect(match!.patternId, 'url',
          reason: 'inline taps never route to the containing command block');
      expect(match.payload, 'https://foo.io');
    });

    test('the block match stays resolvable at the same cell', () async {
      await writeAndScan('\$ curl https://foo.io now\r\n');

      final block = controller.matchAt(row: 0, col: 8, tier: TextTier.block);
      expect(block, isNotNull);
      expect(block!.patternId, 'cmd');
      expect(block.tier, TextTier.block);

      final span = controller.matchAt(row: 0, col: 8, tier: TextTier.span);
      expect(span, isNotNull);
      expect(span!.patternId, 'url');
    });

    test('a block-only cell resolves the block match by default', () async {
      await writeAndScan('\$ curl https://foo.io now\r\n');

      // Col 3 ('u' of curl) is inside the command but outside the URL.
      final match = controller.matchAt(row: 0, col: 3);
      expect(match, isNotNull);
      expect(match!.patternId, 'cmd');
      // But scoped to span, there is nothing there.
      expect(controller.matchAt(row: 0, col: 3, tier: TextTier.span), isNull);
    });

    test('the prompt cell is un-anchored ink (rangeGroup)', () async {
      await writeAndScan('\$ curl https://foo.io now\r\n');

      // Col 0 is the '$' prompt — excluded from the block anchor by
      // rangeGroup, and no span covers it either.
      expect(controller.matchAt(row: 0, col: 0), isNull);
      expect(
        controller.matchAt(row: 0, col: 0, tier: TextTier.block),
        isNull,
      );
    });
  });
}
