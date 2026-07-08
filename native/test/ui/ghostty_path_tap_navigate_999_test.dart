// #999 — a single TAP on a detected PATH anchor NAVIGATES (opens this app's
// SFTP file browser); copy moves to the long-press / gutter menus. URL and
// OSC-8 anchors keep #988's tap-copy unchanged.
//
// Three layers, all headless (NO flterm native `.so`):
//   1. PURE dir-vs-file rule `ghosttyPathBrowseTarget`: trailing slash → the
//      dir itself; anything else (extension-like or unknowable without a stat)
//      → the PARENT dir. Root stays `/`.
//   2. PURE tap dispatch `ghosttyTapMatchAction`: a `path` match invokes the
//      navigate seam (openPath spy) and NEVER the clipboard; url/osc8 matches
//      still route through `ghosttyTapCopyMatch` (copy spy).
//   3. WIDGET: a tap routed by the gesture router at a path cell reaches the
//      navigate seam end to end; the long-press path menu still offers
//      "Copy path" (copy stays one interaction away).

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/path_action_overlay.dart';

void main() {
  const pathMatch = StructuredMatch(
    patternId: kGhosttyPathPatternId,
    payload: '/etc/ssh/sshd_config',
    ranges: [
      HighlightRange(startRow: 2, startCol: 4, endRow: 2, endCol: 24),
    ],
  );
  const urlMatch = StructuredMatch(
    patternId: kGhosttyUrlPatternId,
    payload: 'https://example.com',
    ranges: [
      HighlightRange(startRow: 5, startCol: 4, endRow: 5, endCol: 23),
    ],
  );

  group('#999 ghosttyPathBrowseTarget (pure dir-vs-file rule)', () {
    test('a file-like path opens its PARENT directory', () {
      expect(ghosttyPathBrowseTarget('/etc/hosts'), '/etc');
      expect(ghosttyPathBrowseTarget('/a/b/c.tar.gz'), '/a/b');
      expect(ghosttyPathBrowseTarget('/etc/ssh/sshd_config'), '/etc/ssh');
    });

    test('no trailing slash and no extension is UNKNOWABLE → parent', () {
      // Without an SFTP stat (deferred to #990's infra) a bare segment can't
      // be classified — the parent listing still shows it one tap away.
      expect(ghosttyPathBrowseTarget('/etc'), '/');
      expect(ghosttyPathBrowseTarget('/home/dev/workspace'), '/home/dev');
    });

    test('a trailing slash is plausibly a DIR → open it directly', () {
      expect(ghosttyPathBrowseTarget('/etc/'), '/etc');
      expect(ghosttyPathBrowseTarget('/var/log/'), '/var/log');
      expect(ghosttyPathBrowseTarget('/opt//'), '/opt');
    });

    test('root and near-root edges never escape /', () {
      expect(ghosttyPathBrowseTarget('/'), '/');
      expect(ghosttyPathBrowseTarget('//'), '/');
      expect(ghosttyPathBrowseTarget('/file'), '/');
      expect(ghosttyPathBrowseTarget(''), '/');
      expect(ghosttyPathBrowseTarget('   '), '/');
    });

    test('surrounding whitespace is trimmed before the rule applies', () {
      expect(ghosttyPathBrowseTarget('  /etc/hosts  '), '/etc');
      expect(ghosttyPathBrowseTarget(' /etc/ '), '/etc');
    });
  });

  group('#999 tap dispatch: paths NAVIGATE, URLs copy', () {
    test('a path match invokes openPath with its payload — NEVER copy', () async {
      final opened = <String>[];
      var copyCalls = 0;
      final toast = await ghosttyTapMatchAction(
        pathMatch,
        copy: (_) async {
          copyCalls++;
          return true;
        },
        openPath: (path) async {
          opened.add(path);
          return true;
        },
      );
      expect(opened, ['/etc/ssh/sshd_config']);
      expect(copyCalls, 0, reason: 'a path tap must not touch the clipboard');
      expect(toast, isNull, reason: 'navigation IS the feedback — no toast');
    });

    test('a URL match still tap-copies (unchanged #988 behaviour)', () async {
      final copied = <String>[];
      var openCalls = 0;
      final toast = await ghosttyTapMatchAction(
        urlMatch,
        copy: (text) async {
          copied.add(text);
          return true;
        },
        openPath: (_) async {
          openCalls++;
          return true;
        },
      );
      expect(copied, ['https://example.com']);
      expect(openCalls, 0);
      expect(toast, 'Copied URL');
    });

    test('an OSC-8 match still tap-copies', () async {
      const osc8 = StructuredMatch(
        patternId: kGhosttyOsc8PatternId,
        payload: 'https://example.com/osc8',
        ranges: [
          HighlightRange(startRow: 1, startCol: 0, endRow: 1, endCol: 8),
        ],
      );
      final copied = <String>[];
      final toast = await ghosttyTapMatchAction(
        osc8,
        copy: (text) async {
          copied.add(text);
          return true;
        },
        openPath: (_) async => true,
      );
      expect(copied, ['https://example.com/osc8']);
      expect(toast, 'Copied URL');
    });

    test('an empty path payload neither navigates nor copies (#810 guard)', () async {
      const empty = StructuredMatch(
        patternId: kGhosttyPathPatternId,
        payload: '  ',
        ranges: [
          HighlightRange(startRow: 1, startCol: 0, endRow: 1, endCol: 2),
        ],
      );
      var openCalls = 0;
      var copyCalls = 0;
      final toast = await ghosttyTapMatchAction(
        empty,
        copy: (_) async {
          copyCalls++;
          return true;
        },
        openPath: (_) async {
          openCalls++;
          return true;
        },
      );
      expect(openCalls, 0);
      expect(copyCalls, 0);
      expect(toast, isNull);
    });
  });

  group('#999 router tap on a path cell reaches the navigate seam', () {
    Future<void> pumpRouter(
      WidgetTester tester, {
      required List<String> opened,
      required List<String> copied,
    }) async {
      StructuredMatch? matchAt(int col, int row) {
        if (pathMatch.contains(row, col)) return pathMatch;
        if (urlMatch.contains(row, col)) return urlMatch;
        return null;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 400,
                child: GhosttyPointerGestureRouter(
                  active: false,
                  scrollController: TerminalScrollController(),
                  cols: 50,
                  rows: 24,
                  lastSentCols: 50,
                  lastSentRows: 24,
                  cellWidth: 8,
                  cellHeight: 16,
                  mouseTrackingLabel: 'any',
                  onTap: () {},
                  onFocus: () {},
                  onMouseReport: (_) {},
                  onSelectionStart: (_, _) {},
                  onSelectionExtend: (_, _) {},
                  hasSelection: () => false,
                  onSelectionClear: () {},
                  urlAtCell: matchAt,
                  onUrlTap: (m) => ghosttyTapMatchAction(
                    m,
                    copy: (text) async {
                      copied.add(text);
                      return true;
                    },
                    openPath: (path) async {
                      opened.add(path);
                      return true;
                    },
                  ),
                  onUrlLongPress: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('path cell tap → navigate seam, clipboard untouched', (
      tester,
    ) async {
      final opened = <String>[];
      final copied = <String>[];
      await pumpRouter(tester, opened: opened, copied: copied);
      // Path match on row 2, cols 4..23 → cell (6,2) → px (6*8+4, 2*16+8).
      await tester.tapAt(const Offset(52, 40));
      await tester.pumpAndSettle();
      expect(opened, ['/etc/ssh/sshd_config']);
      expect(copied, isEmpty, reason: 'a path tap must NOT copy (#999)');
    });

    testWidgets('URL cell tap still copies, never navigates', (tester) async {
      final opened = <String>[];
      final copied = <String>[];
      await pumpRouter(tester, opened: opened, copied: copied);
      // URL match on row 5, cols 4..22 → cell (6,5) → px (6*8+4, 5*16+8).
      await tester.tapAt(const Offset(52, 88));
      await tester.pumpAndSettle();
      expect(copied, ['https://example.com']);
      expect(opened, isEmpty);
    });
  });

  group('#999 long-press path menu keeps "Copy path"', () {
    testWidgets('showPathActions offers Copy path AND Open', (tester) async {
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
      expect(find.byKey(const Key('path-action-menu')), findsOneWidget);
      expect(
        find.byKey(const Key('path-action-copy')),
        findsOneWidget,
        reason: 'copy must stay one interaction away (long-press → Copy path)',
      );
      expect(find.text('Copy path'), findsOneWidget);
      expect(find.byKey(const Key('path-action-open')), findsOneWidget);
      // In-body (not addTearDown — that runs AFTER the pending-timer check):
      // cancel the overlay's auto-dismiss timer via the documented test seam.
      debugDismissPathActions();
      await tester.pump();
    });
  });
}
