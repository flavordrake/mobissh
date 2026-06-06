// #778 paths Slice 1 — a tap/long-press on a detected absolute file PATH routes
// to the SFTP file explorer (Open), not the URL clipboard path.
//
// Three layers, all headless (NO flterm native `.so`):
//   1. the pure routing decision `ghosttyLongPressShowsPathMenu` (path-only);
//   2. the gesture router fires its match callback with a `path` StructuredMatch
//      when a tap/long-press lands on a path cell (mirrors the URL router test);
//   3. `openFileBrowser(..., initialPath:)` actually pushes a FileBrowserScreen
//      AT that path — the acceptance that a path tap opens the explorer there.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

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
      HighlightRange(startRow: 2, startCol: 4, endRow: 2, endCol: 15),
    ],
  );

  group('#778 pure routing decision', () {
    test('ghosttyLongPressShowsPathMenu true ONLY for a `path` match', () {
      expect(ghosttyLongPressShowsPathMenu(pathMatch), isTrue);
      expect(
        ghosttyLongPressShowsPathMenu(urlMatch),
        isFalse,
        reason: 'a URL match is owned by the URL menu, not the path menu',
      );
      expect(ghosttyLongPressShowsPathMenu(null), isFalse);
    });
  });

  group('#778 gesture router fires its callback for a path cell', () {
    late List<StructuredMatch> tapMatches;
    late List<StructuredMatch> longPresses;

    Future<void> pumpRouter(WidgetTester tester) async {
      tapMatches = [];
      longPresses = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 400,
                child: GhosttyPointerGestureRouter(
                  active: false, // plain shell: tap-copy/open path is wired here too
                  scrollController: TerminalScrollController(),
                  cols: 80,
                  rows: 24,
                  lastSentCols: 80,
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
                  urlAtCell: (col, row) =>
                      pathMatch.contains(row, col) ? pathMatch : null,
                  onUrlTap: tapMatches.add,
                  onUrlLongPress: (m, _) => longPresses.add(m),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a tap on a path cell fires onUrlTap with the path match', (
      tester,
    ) async {
      await pumpRouter(tester);
      // Cell row 2 (0-based) → py [36,52); col 6 (inside 4..23) → px [52,60).
      await tester.tapAt(const Offset(54, 44));
      await tester.pumpAndSettle();

      expect(tapMatches, hasLength(1));
      expect(tapMatches.single.patternId, kGhosttyPathPatternId);
      expect(tapMatches.single.payload, '/etc/ssh/sshd_config');
    });
  });

  group('#778 openFileBrowser(initialPath:) opens the explorer at the path', () {
    testWidgets('pushes a FileBrowserScreen whose initialPath is the path', (
      tester,
    ) async {
      FileBrowserScreen? pushed;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => openFileBrowser(
                    context,
                    'sess-1',
                    initialPath: '/etc/ssh/sshd_config',
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
            navigatorObservers: [_CaptureObserver((route) {
              final w = (route as MaterialPageRoute).builder(
                _DummyContext(),
              );
              if (w is FileBrowserScreen) pushed = w;
            })],
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(pushed, isNotNull, reason: 'openFileBrowser must push the screen');
      expect(pushed!.initialPath, '/etc/ssh/sshd_config');
      expect(pushed!.sessionId, 'sess-1');
    });
  });
}

/// Captures each pushed route so the test can inspect the screen it builds.
class _CaptureObserver extends NavigatorObserver {
  _CaptureObserver(this.onPush);
  final void Function(Route<dynamic> route) onPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is MaterialPageRoute) onPush(route);
    super.didPush(route, previousRoute);
  }
}

/// A throwaway BuildContext for building the pushed route's widget in the test.
class _DummyContext extends StatelessElement {
  _DummyContext() : super(const _DummyWidget());
}

class _DummyWidget extends StatelessWidget {
  const _DummyWidget();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
