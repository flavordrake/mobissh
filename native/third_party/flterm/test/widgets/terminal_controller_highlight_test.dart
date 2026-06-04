@Tags(['ffi'])
library;

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalController highlights', () {
    late TerminalControllerImpl controller;

    setUp(() => controller = TerminalControllerImpl());
    tearDown(() => controller.dispose());

    test('starts with no highlights', () {
      expect(controller.highlights, isEmpty);
      expect(controller.highlightAt(row: 0, col: 0), isNull);
    });

    test('setting highlights notifies listeners once', () {
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.highlights = const [
        HighlightRange(startRow: 0, startCol: 0, endRow: 0, endCol: 4),
      ];

      expect(controller.highlights, hasLength(1));
      expect(notifications, 1);
    });

    test('setting the identical list does not notify', () {
      const ranges = [
        HighlightRange(startRow: 0, startCol: 0, endRow: 0, endCol: 4),
      ];
      controller.highlights = ranges;

      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.highlights = ranges;

      expect(notifications, 0);
    });

    test('highlightAt returns the covering range with its payload', () {
      controller.highlights = const [
        HighlightRange(
          startRow: 1,
          startCol: 3,
          endRow: 1,
          endCol: 9,
          payload: 'https://example.com',
        ),
      ];

      final hit = controller.highlightAt(row: 1, col: 5);
      expect(hit, isNotNull);
      expect(hit!.payload, 'https://example.com');
    });

    test('highlightAt returns null outside every range', () {
      controller.highlights = const [
        HighlightRange(startRow: 1, startCol: 3, endRow: 1, endCol: 9),
      ];

      expect(controller.highlightAt(row: 1, col: 2), isNull);
      expect(controller.highlightAt(row: 1, col: 9), isNull);
      expect(controller.highlightAt(row: 0, col: 5), isNull);
    });

    test('highlightAt resolves a multi-row range', () {
      controller.highlights = const [
        HighlightRange(
          startRow: 0,
          startCol: 6,
          endRow: 2,
          endCol: 4,
          payload: 'multi',
        ),
      ];

      // Top row: only from startCol onward.
      expect(controller.highlightAt(row: 0, col: 6)?.payload, 'multi');
      expect(controller.highlightAt(row: 0, col: 5), isNull);
      // Middle row: fully covered.
      expect(controller.highlightAt(row: 1, col: 0)?.payload, 'multi');
      // Bottom row: up to bottomCol (exclusive).
      expect(controller.highlightAt(row: 2, col: 3)?.payload, 'multi');
      expect(controller.highlightAt(row: 2, col: 4), isNull);
    });

    test('the last overlapping range wins', () {
      controller.highlights = const [
        HighlightRange(
          startRow: 0,
          startCol: 0,
          endRow: 0,
          endCol: 10,
          payload: 'under',
        ),
        HighlightRange(
          startRow: 0,
          startCol: 2,
          endRow: 0,
          endCol: 6,
          payload: 'over',
        ),
      ];

      expect(controller.highlightAt(row: 0, col: 4)?.payload, 'over');
      expect(controller.highlightAt(row: 0, col: 8)?.payload, 'under');
    });
  });
}
