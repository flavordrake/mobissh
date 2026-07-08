// #955 — the right-edge GUTTER layer that replaced the inline URL bubble / path
// underline. Covers (1) the PURE grouping of anchors → gutter rows, and (2) the
// WIDGET behaviour: marks appear only on matched rows, TRACK the scroll by
// re-resolving their viewport row on every decoration notify (#993 — no
// mid-scroll hide; that is the bubble's contract, not the gutter's), a
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
/// surface [GhosttyGutterLayer] reads. #993: [setOffset] models a painted-offset
/// change mid-scroll — the real controller's decorationListenable fires post-frame
/// on every painted-offset change and anchorGutterRow re-resolves against it.
class _FakeController extends ChangeNotifier implements TerminalController {
  List<StructuredAnchor> _anchors = const [];
  bool _scrolling = false;
  int _offset = 0;
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

  /// A painted-offset step: rows re-resolve as `topRow - offset`; the scroll
  /// flag defaults ON (this is what happens DURING a scroll, #993).
  void setOffset(int value, {bool scrolling = true}) {
    _offset = value;
    _scrolling = scrolling;
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
    final row = range.topRow - _offset;
    if (row < 0 || row >= viewportRows) return null;
    return row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A test-owned verification signal (#990) — stands in for the
/// SessionPathVerifier's ChangeNotifier surface.
class _TestSignal extends ChangeNotifier {
  void fire() => notifyListeners();
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
      Color color = const Color(0xFF5B9BD5),
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
                    color: color,
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

    // #993 — the chips TRACK their line during a scroll instead of hiding
    // (the owner saw them pinned to fixed viewport rows while the text moved).
    // Every painted-offset notify re-resolves each anchor's viewport row via
    // anchorGutterRow, so the mark moves in lockstep with the painted glyphs.
    group('scroll tracking (#993)', () {
      testWidgets('marks stay VISIBLE and move to the re-resolved row while '
          'the painted offset changes mid-scroll', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_urlAnchor('https://example.com', row: 10)]);
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-10')), findsOneWidget);

        // The scroll starts: the offset moves 3 rows, isScrolling is true.
        controller.setOffset(3);
        await tester.pump();
        expect(
          find.byKey(const Key('gutter-mark-7')),
          findsOneWidget,
          reason: 'the mark must TRACK its line to the new viewport row (#993)',
        );
        expect(
          find.byKey(const Key('gutter-mark-10')),
          findsNothing,
          reason: 'the mark must not stay pinned to the old viewport row',
        );

        // A further step mid-scroll keeps tracking.
        controller.setOffset(6);
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-4')), findsOneWidget);
      });

      testWidgets('a mark scrolled OFF-screen disappears and returns when '
          'scrolled back on-screen', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_urlAnchor('https://example.com', row: 2)]);
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-2')), findsOneWidget);

        controller.setOffset(5); // row 2 - 5 → above the viewport
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark--3')), findsNothing);
        expect(find.byKey(const Key('gutter-mark-2')), findsNothing);

        controller.setOffset(0);
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-2')), findsOneWidget);
      });

      testWidgets('settle keeps the mark at the settled offset row',
          (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_urlAnchor('https://example.com', row: 9)]);
        await tester.pump();

        controller.setOffset(4); // scrolling
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-5')), findsOneWidget);

        controller.setScrolling(false); // trailing-edge settle notify
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-5')), findsOneWidget);
      });

      testWidgets('taps are IGNORED while scrolling (a chip can change rows '
          'between tapDown and tapUp)', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_urlAnchor('https://example.com', row: 10)]);
        controller.setOffset(3);
        await tester.pump();

        await tester.tap(find.byKey(const Key('gutter-mark-7')));
        await tester.pump();
        expect(
          find.byKey(const Key('url-action-menu')),
          findsNothing,
          reason: 'mid-scroll the chip under the finger is not a stable '
              'target — no action may fire (#993)',
        );

        controller.setScrolling(false);
        await tester.pump();
        await tester.tap(find.byKey(const Key('gutter-mark-7')));
        await tester.pump();
        expect(find.byKey(const Key('url-action-menu')), findsOneWidget);
        debugDismissUrlActions();
      });

      testWidgets('#990 verified shade and visibility gating hold mid-scroll',
          (tester) async {
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
                        openPath: (_) async => true,
                      ),
                      color: const Color(0xFF5B9BD5),
                      cellHeight: 20,
                      isVerified: (a) => a.payload == '/etc/hosts',
                      isVisible: (a) => '${a.payload}' != '/config',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        controller.setAnchors([
          _pathAnchor('/etc/hosts', row: 8),
          _pathAnchor('/config', row: 12),
        ]);
        controller.setOffset(2); // scrolling
        await tester.pump();

        // The verified path tracks to row 6 and keeps the bold ring.
        final boxes = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('gutter-mark-6')),
            matching: find.byType(DecoratedBox),
          ),
        );
        final deco = boxes
            .map((b) => b.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.color != null);
        expect(deco.border, isNotNull,
            reason: 'the verified bold ring must survive scroll tracking');
        // The suppressed anchor renders nothing at its tracked row either.
        expect(find.byKey(const Key('gutter-mark-10')), findsNothing);
      });
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

    // #989 — the mark must read as a physical tappable BUTTON: a filled chip
    // backing (high contrast against terminal text), a bigger glyph, a >=40dp
    // effective touch target, and pressed feedback. Visual/affordance only —
    // the dispatch tests above must stay green unchanged.
    group('mark affordance (#989)', () {
      /// The chip [DecoratedBox] inside the mark for [row] — the FILLED backing
      /// (a BoxDecoration with a colour), not the translucent strip.
      BoxDecoration chipDecorationOf(WidgetTester tester, int row) {
        final boxes = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(Key('gutter-mark-$row')),
            matching: find.byType(DecoratedBox),
          ),
        );
        return boxes
                .map((b) => b.decoration)
                .whereType<BoxDecoration>()
                .firstWhere((d) => d.color != null)
            ;
      }

      testWidgets('mark hit target is at least 40x40 logical px', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_urlAnchor('https://example.com', row: 4)]);
        await tester.pump();
        final size = tester.getSize(find.byKey(const Key('gutter-mark-4')));
        expect(size.width, greaterThanOrEqualTo(GutterMarkStyle.normal.minTapExtent));
        expect(size.height, greaterThanOrEqualTo(GutterMarkStyle.normal.minTapExtent));
      });

      testWidgets('mark has an OPAQUE filled chip even from a translucent accent',
          (tester) async {
        // The session selection colour is often translucent (e.g. 0x33 alpha) —
        // the chip must force full opacity or it vanishes over terminal text.
        final controller = await pumpLayer(
          tester,
          color: const Color(0x335B9BD5),
        );
        controller.setAnchors([_urlAnchor('https://example.com', row: 4)]);
        await tester.pump();
        final deco = chipDecorationOf(tester, 4);
        expect(deco.color, isNotNull);
        expect(deco.color!.a, 1.0, reason: 'chip fill must be fully opaque');
      });

      testWidgets('glyphs are bigger and stay DISTINCT per pattern', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([
          _urlAnchor('https://example.com', row: 2),
          _pathAnchor('/etc/hosts', row: 5),
        ]);
        await tester.pump();

        final urlIcon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('gutter-mark-2')),
            matching: find.byType(Icon),
          ),
        );
        final pathIcon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('gutter-mark-5')),
            matching: find.byType(Icon),
          ),
        );
        expect(urlIcon.icon, isNot(pathIcon.icon));
        expect(urlIcon.size, greaterThanOrEqualTo(GutterMarkStyle.normal.glyphSize));
        expect(pathIcon.size, greaterThanOrEqualTo(GutterMarkStyle.normal.glyphSize));
        expect(GutterMarkStyle.normal.glyphSize, greaterThan(14.0),
            reason: 'the legacy faint mark was a bare 14px icon');
      });

      testWidgets('a multi-match count badge gets the chip backing too',
          (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([
          _urlAnchor('https://example.com', row: 5),
          _pathAnchor('/etc/hosts', row: 5),
        ]);
        await tester.pump();
        final deco = chipDecorationOf(tester, 5);
        expect(deco.color!.a, 1.0);
        expect(find.text('2'), findsOneWidget);
      });

      testWidgets('pressed feedback: the chip scales down while the pointer is down',
          (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_urlAnchor('https://example.com', row: 4)]);
        await tester.pump();

        final scaleFinder = find.descendant(
          of: find.byKey(const Key('gutter-mark-4')),
          matching: find.byType(AnimatedScale),
        );
        expect(tester.widget<AnimatedScale>(scaleFinder).scale, 1.0);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('gutter-mark-4'))),
        );
        // Past the tap-deadline so the sole-competitor recognizer fires tapDown.
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.widget<AnimatedScale>(scaleFinder).scale,
          lessThan(1.0),
          reason: 'the mark must visibly respond to touch (physical affordance)',
        );

        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.widget<AnimatedScale>(scaleFinder).scale, 1.0);
        // The tap-up fired the single-URL action overlay — tear it down.
        debugDismissUrlActions();
      });
    });

    // #990 — detected vs VERIFIED path shades. A path anchor whose payload the
    // per-session verifier confirmed (exists on the CONNECTED host via SFTP
    // stat) renders its chip in the BOLD style (a contrast ring); an unverified
    // one keeps the plain detected chip. The layer only consumes an OPAQUE
    // `isVerified` predicate — WHY a path is verified is the caller's business.
    group('verified path shade (#990)', () {
      BoxDecoration chipDecorationOf(WidgetTester tester, int row) {
        final boxes = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(Key('gutter-mark-$row')),
            matching: find.byType(DecoratedBox),
          ),
        );
        return boxes
            .map((b) => b.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.color != null);
      }

      Future<_FakeController> pumpVerifiable(
        WidgetTester tester, {
        required bool Function(StructuredAnchor anchor) isVerified,
        bool Function(StructuredAnchor anchor)? isVisible,
        Listenable? verificationListenable,
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
                        openPath: (_) async => true,
                      ),
                      color: const Color(0xFF5B9BD5),
                      cellHeight: 20,
                      isVerified: isVerified,
                      isVisible: isVisible,
                      verificationListenable: verificationListenable,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return controller;
      }

      test('GutterMarkStyle.bold is a BOLDER variant of normal (ring)', () {
        expect(GutterMarkStyle.normal.ringWidth, 0.0);
        expect(
          GutterMarkStyle.bold.ringWidth,
          greaterThan(0.0),
          reason: 'the verified chip must be visually bolder than detected',
        );
        expect(
          GutterMarkStyle.bold.minTapExtent,
          GutterMarkStyle.normal.minTapExtent,
          reason: 'verification never changes tap semantics',
        );
      });

      testWidgets('an UNVERIFIED path keeps the plain detected chip (no ring)',
          (tester) async {
        final controller = await pumpVerifiable(tester, isVerified: (_) => false);
        controller.setAnchors([_pathAnchor('/no/such/path990', row: 3)]);
        await tester.pump();
        final deco = chipDecorationOf(tester, 3);
        expect(deco.border, isNull);
      });

      testWidgets('a VERIFIED path renders the bold chip (contrast ring)',
          (tester) async {
        final controller = await pumpVerifiable(
          tester,
          isVerified: (a) => a.payload == '/etc/hosts',
        );
        controller.setAnchors([
          _pathAnchor('/etc/hosts', row: 3),
          _pathAnchor('/no/such/path990', row: 5),
        ]);
        await tester.pump();
        final verified = chipDecorationOf(tester, 3);
        expect(verified.border, isNotNull);
        expect(
          verified.border!.top.width,
          GutterMarkStyle.bold.ringWidth,
          reason: 'verified chip carries the bold ring',
        );
        final detected = chipDecorationOf(tester, 5);
        expect(detected.border, isNull,
            reason: 'the fake path on the SAME layer stays detected');
      });

      testWidgets(
          'a verification arriving LATER upgrades the chip (listenable-driven)',
          (tester) async {
        final verified = <String>{};
        final signal = _TestSignal();
        addTearDown(signal.dispose);
        final controller = await pumpVerifiable(
          tester,
          isVerified: (a) => verified.contains('${a.payload}'),
          verificationListenable: signal,
        );
        controller.setAnchors([_pathAnchor('/etc/hosts', row: 4)]);
        await tester.pump();
        expect(chipDecorationOf(tester, 4).border, isNull);

        // The async SFTP stat lands: the verifier notifies, no anchor change.
        verified.add('/etc/hosts');
        signal.fire();
        await tester.pump();
        expect(
          chipDecorationOf(tester, 4).border,
          isNotNull,
          reason: 'the layer must repaint on verification results, not only '
              'on anchor changes',
        );
      });

      // #990 visibility gate: a SUPPRESSED anchor (single-segment root match
      // not yet verified — pending or missing) renders NO chip at all; it
      // appears once the verifier confirms existence.
      testWidgets('a suppressed anchor renders NO mark until it becomes '
          'visible (listenable-driven)', (tester) async {
        final visible = <String>{};
        final signal = _TestSignal();
        addTearDown(signal.dispose);
        final controller = await pumpVerifiable(
          tester,
          isVerified: (_) => false,
          isVisible: (a) => visible.contains('${a.payload}'),
          verificationListenable: signal,
        );
        controller.setAnchors([_pathAnchor('/config', row: 4)]);
        await tester.pump();
        expect(
          find.byKey(const Key('gutter-mark-4')),
          findsNothing,
          reason: 'an unverified single-segment match must show NO affordance',
        );

        // The stat confirms it exists → the chip appears.
        visible.add('/config');
        signal.fire();
        await tester.pump();
        expect(find.byKey(const Key('gutter-mark-4')), findsOneWidget);
      });

      testWidgets('a multi-match row drops a suppressed anchor from its count',
          (tester) async {
        final controller = await pumpVerifiable(
          tester,
          isVerified: (_) => false,
          isVisible: (a) => '${a.payload}' != '/config',
        );
        controller.setAnchors([
          _urlAnchor('https://example.com', row: 6),
          _pathAnchor('/config', row: 6),
        ]);
        await tester.pump();
        // Only the URL remains → a single-pattern glyph mark, no count badge.
        expect(find.byKey(const Key('gutter-mark-6')), findsOneWidget);
        expect(find.text('2'), findsNothing);
      });

      testWidgets('a multi-match row with ONE verified anchor uses the bold chip',
          (tester) async {
        final controller = await pumpVerifiable(
          tester,
          isVerified: (a) => a.payload == '/etc/hosts',
        );
        controller.setAnchors([
          _urlAnchor('https://example.com', row: 6),
          _pathAnchor('/etc/hosts', row: 6),
        ]);
        await tester.pump();
        expect(chipDecorationOf(tester, 6).border, isNotNull);
        expect(find.text('2'), findsOneWidget);
      });
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
