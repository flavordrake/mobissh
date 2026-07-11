// #1036 — RELATIVE-path anchor actions work in RESOLVED-ABSOLUTE semantics.
//
// Headless (no flterm native .so):
//   1. PURE tap dispatch: a `relpath` match navigates to the RESOLVED path
//      (the injected cwd resolver), never the clipboard.
//   2. Long-press menu: showPathActions with `relativeText` offers BOTH
//      "Copy relative" (the matched text) and "Copy path" (the resolved
//      absolute), plus Open.
//   3. Gutter registry: the relpath presentation exists and its list-sheet
//      actions carry open / copy / copy-relative / not-a-file.
//   4. Long-press routing: a relpath match qualifies for the path menu.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/path_action_overlay.dart';

void main() {
  const relMatch = StructuredMatch(
    patternId: kGhosttyRelPathPatternId,
    payload: 'sub/real.txt',
    ranges: [
      HighlightRange(startRow: 2, startCol: 4, endRow: 2, endCol: 16),
    ],
  );

  group('#1036 tap dispatch: relpath navigates to the RESOLVED absolute', () {
    test('openPath receives cwd-resolved path; clipboard untouched', () async {
      final opened = <String>[];
      var copyCalls = 0;
      final toast = await ghosttyTapMatchAction(
        relMatch,
        copy: (_) async {
          copyCalls++;
          return true;
        },
        openPath: (path) async {
          opened.add(path);
          return true;
        },
        resolveRelative: (rel) => '/tmp/work/$rel',
      );
      expect(opened, ['/tmp/work/sub/real.txt']);
      expect(copyCalls, 0);
      expect(toast, isNull, reason: 'navigation IS the feedback');
    });

    test('without a resolver the raw relative still reaches openPath', () async {
      final opened = <String>[];
      await ghosttyTapMatchAction(
        relMatch,
        copy: (_) async => true,
        openPath: (path) async {
          opened.add(path);
          return true;
        },
      );
      expect(opened, ['sub/real.txt']);
    });
  });

  group('#1036 long-press routing', () {
    test('a relpath match qualifies for the PATH menu (not selection)', () {
      expect(ghosttyLongPressShowsPathMenu(relMatch), isTrue);
    });
  });

  group('#1036 path menu offers Copy relative AND Copy path', () {
    testWidgets('relativeText adds the Copy relative action', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showPathActions(
                  context,
                  '/tmp/work/sub/real.txt',
                  relativeText: 'sub/real.txt',
                  highlightRects: const [],
                  anchor: const Offset(200, 200),
                ),
                child: const Text('menu'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('menu'));
      await tester.pump();
      expect(find.byKey(const Key('path-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('path-action-copy')), findsOneWidget);
      expect(
        find.byKey(const Key('path-action-copy-relative')),
        findsOneWidget,
        reason: 'the menu must offer the relative text AND the absolute',
      );
      expect(find.text('Copy relative'), findsOneWidget);
      expect(find.byKey(const Key('path-action-open')), findsOneWidget);
      debugDismissPathActions();
      await tester.pump();
    });

    testWidgets('without relativeText the extra action is absent', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showPathActions(
                  context,
                  '/etc/hosts',
                  highlightRects: const [],
                  anchor: const Offset(200, 200),
                ),
                child: const Text('menu'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('menu'));
      await tester.pump();
      expect(
        find.byKey(const Key('path-action-copy-relative')),
        findsNothing,
      );
      debugDismissPathActions();
      await tester.pump();
    });
  });

  group('#1036 gutter registry relpath presentation', () {
    test('registered under the relpath id with resolved-absolute actions', () {
      final registry = GutterPatternRegistry.standard(
        openPath: (_) async => true,
        resolveRelative: (rel) => '/cwd/$rel',
        onReportException: (_, _) {},
      );
      final presentation = registry.forPattern(kGhosttyRelPathPatternId);
      expect(presentation, isNotNull);
      final actions = presentation!.itemActions('sub/real.txt');
      expect(
        actions.map((a) => a.keyLabel),
        containsAll(<String>['open', 'copy', 'copy-relative', 'not']),
      );
      expect(
        actions.map((a) => a.label),
        containsAll(<String>['Open', 'Copy path', 'Copy relative', 'Not a file']),
      );
    });
  });
}
