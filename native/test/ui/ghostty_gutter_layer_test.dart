// #955 — the right-edge GUTTER layer that replaced the inline URL bubble / path
// underline. Covers (1) the PURE grouping of anchors → gutter rows, and (2) the
// WIDGET behaviour: marks appear only on matched rows, hide while scrolling, a
// single-match mark taps straight to the action overlay, and a multi-match mark
// opens the list sheet whose items dispatch to the right action (a path item
// opens the SFTP browser at its path).
//
// No FFI: a fake controller supplies scripted anchors + gutter rows, so this
// runs in the fast gate. The touch-target size / real-vsync scroll tracking /
// which side clears flterm's scrollbar is DEVICE-class (feedback_device_run_not_
// headless_green) — covered on the emulator, not here.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/path_action_overlay.dart';
import 'package:mobissh/ui/url_action_overlay.dart';

StructuredAnchor _urlAnchor(String url, {int row = 2}) => StructuredAnchor(
  patternId: kGhosttyUrlPatternId,
  payload: url,
  ranges: [
    HighlightRange(
      startRow: row,
      startCol: 4,
      endRow: row,
      endCol: 4 + url.length,
      payload: url,
    ),
  ],
);

StructuredAnchor _pathAnchor(String path, {int row = 2}) => StructuredAnchor(
  patternId: kGhosttyPathPatternId,
  payload: path,
  ranges: [
    HighlightRange(
      startRow: row,
      startCol: 0,
      endRow: row,
      endCol: path.length,
      payload: path,
    ),
  ],
);

/// A multi-row (soft-wrapped) anchor: one range per [rows] entry, in order.
StructuredAnchor _wrappedUrl(String url, List<int> rows) => StructuredAnchor(
  patternId: kGhosttyUrlPatternId,
  payload: url,
  ranges: [
    for (final r in rows)
      HighlightRange(startRow: r, startCol: 0, endRow: r, endCol: 5, payload: url),
  ],
);

/// Fake controller exposing scripted [anchors] + an [anchorGutterRow] that maps a
/// range's top row to a viewport row (null when off [viewportRows]). The only
/// surface [GhosttyGutterLayer] reads.
class _FakeController extends ChangeNotifier implements TerminalController {
  List<StructuredAnchor> _anchors = const [];
  bool _scrolling = false;
  int viewportRows = 24;

  void setAnchors(List<StructuredAnchor> value) {
    _anchors = value;
    notifyListeners();
  }

  void setScrolling(bool value) {
    if (_scrolling == value) return;
    _scrolling = value;
    notifyListeners();
  }

  @override
  List<StructuredAnchor> get anchors => _anchors;

  @override
  bool get isScrolling => _scrolling;

  @override
  Listenable get decorationListenable => this;

  @override
  int? anchorGutterRow(HighlightRange range) {
    final row = range.topRow;
    if (row < 0 || row >= viewportRows) return null;
    return row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('groupAnchorsByGutterRow (pure)', () {
    test('groups several matches on the SAME row under one key', () {
      final byRow = groupAnchorsByGutterRow(
        [_urlAnchor('u', row: 3), _pathAnchor('/p', row: 3)],
        gutterRowOf: (r) => r.topRow,
        hasPresentation: (_) => true,
      );
      expect(byRow.keys, [3]);
      expect(byRow[3], hasLength(2));
    });

    test('a multi-row anchor collapses to its FIRST on-screen row', () {
      // First range off-screen (null), second on-screen → one mark at row 5.
      final byRow = groupAnchorsByGutterRow(
        [_wrappedUrl('u', [-1, 5])],
        gutterRowOf: (r) => r.topRow >= 0 ? r.topRow : null,
        hasPresentation: (_) => true,
      );
      expect(byRow.keys, [5]);
      expect(byRow[5], hasLength(1));
    });

    test('an anchor whose every range is off-screen is EXCLUDED', () {
      final byRow = groupAnchorsByGutterRow(
        [_urlAnchor('u', row: -3)],
        gutterRowOf: (r) => r.topRow >= 0 ? r.topRow : null,
        hasPresentation: (_) => true,
      );
      expect(byRow, isEmpty);
    });

    test('an anchor with no registered presentation is EXCLUDED', () {
      final shaAnchor = StructuredAnchor(
        patternId: 'commit-sha',
        payload: 'deadbeef',
        ranges: const [
          HighlightRange(startRow: 2, startCol: 0, endRow: 2, endCol: 8),
        ],
      );
      final byRow = groupAnchorsByGutterRow(
        [shaAnchor],
        gutterRowOf: (r) => r.topRow,
        hasPresentation: (id) => id != 'commit-sha',
      );
      expect(byRow, isEmpty);
    });
  });

  group('GhosttyGutterLayer', () {
    Future<_FakeController> pumpLayer(
      WidgetTester tester, {
      Future<bool> Function(String path)? openPath,
      double cellHeight = 20,
    }) async {
      final controller = _FakeController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GhosttyGutterLayer(
                    controller: controller,
                    registry: GutterPatternRegistry.standard(
                      openPath: openPath ?? (_) async => true,
                    ),
                    color: const Color(0xFF5B9BD5),
                    cellHeight: cellHeight,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('renders a mark ONLY on matched rows', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com', row: 4)]);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-4')), findsOneWidget);
      expect(find.byKey(const Key('gutter-mark-3')), findsNothing);
    });

    testWidgets('renders nothing when there are no anchors', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors(const []);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-2')), findsNothing);
    });

    testWidgets('HIDES marks while scrolling, re-shows on settle', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com', row: 4)]);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-4')), findsOneWidget);

      controller.setScrolling(true);
      await tester.pump();
      expect(
        find.byKey(const Key('gutter-mark-4')),
        findsNothing,
        reason: 'marks hide while the painted offset is changing (#812/#955)',
      );

      controller.setScrolling(false);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-4')), findsOneWidget);
    });

    testWidgets('a multi-match row shows a count mark', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _urlAnchor('https://example.com', row: 5),
        _pathAnchor('/etc/hosts', row: 5),
      ]);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-5')), findsOneWidget);
      // The count badge shows the number of matches on the line.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('tap a single URL mark → the URL action overlay', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_urlAnchor('https://example.com', row: 2)]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-2')));
      await tester.pump();
      expect(find.byKey(const Key('url-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('path-action-menu')), findsNothing);
      // Tear down the overlay + its 6s auto-dismiss timer before the test ends.
      debugDismissUrlActions();
    });

    testWidgets('tap a single PATH mark → the path action overlay',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_pathAnchor('/etc/hosts', row: 2)]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-2')));
      await tester.pump();
      expect(find.byKey(const Key('path-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('url-action-menu')), findsNothing);
      // Tear down the overlay + its 6s auto-dismiss timer before the test ends.
      debugDismissPathActions();
    });

    testWidgets('tap a multi-pattern mark → the list sheet with each item',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _urlAnchor('https://example.com', row: 6),
        _pathAnchor('/etc/hosts', row: 6),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-6')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('gutter-pattern-list')), findsOneWidget);
      expect(find.byKey(const Key('gutter-item-0')), findsOneWidget);
      expect(find.byKey(const Key('gutter-item-1')), findsOneWidget);
      expect(find.text('https://example.com'), findsOneWidget);
      expect(find.text('/etc/hosts'), findsOneWidget);
    });

    testWidgets('tap a PATH item in the list sheet → opens the browser at path',
        (tester) async {
      String? openedPath;
      final controller = await pumpLayer(
        tester,
        openPath: (p) async {
          openedPath = p;
          return true;
        },
      );
      controller.setAnchors([
        _urlAnchor('https://example.com', row: 6),
        _pathAnchor('/etc/hosts', row: 6),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-6')));
      await tester.pumpAndSettle();

      // anchors = [url, path] → item 1 is the path; its first action is Open.
      await tester.tap(find.byKey(const Key('gutter-item-1-open')));
      await tester.pumpAndSettle();
      expect(openedPath, '/etc/hosts');
    });
  });
}
