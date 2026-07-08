// #994 — a file:// URL detected in terminal output is a REMOTE PATH on the
// SSH host, not a browser URL. Classification happens by SCHEME at the ACTION
// layer (detection is untouched: file:// anchors come from the url/osc8
// patterns):
//   1. PURE classification `ghosttyFileUrlPath`: a url/osc8 match whose
//      payload is a well-formed file:// URI yields the bare decoded path;
//      anything else (http URLs, path-pattern matches, malformed file://)
//      yields null.
//   2. TAP dispatch `ghosttyTapMatchAction`: a file:// match NAVIGATES through
//      the SAME openPath seam #999 built — never the clipboard. http(s)/OSC-8
//      web URLs keep #988's tap-copy unchanged.
//   3. MENU: showPathActions grows an optional "Copy sftp URL" action; the
//      gutter registry routes a file:// url/osc8 anchor to the PATH menu
//      (Open / Copy path / Copy sftp URL) and a web URL to the URL menu.
//
// All headless (no flterm native .so): matches/anchors are constructed
// directly, sinks are spies.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/path_action_overlay.dart';
import 'package:mobissh/ui/url_action_overlay.dart';

StructuredMatch _match(String patternId, String payload) => StructuredMatch(
  patternId: patternId,
  payload: payload,
  ranges: [
    HighlightRange(
      startRow: 2,
      startCol: 0,
      endRow: 2,
      endCol: payload.length,
      payload: payload,
    ),
  ],
);

StructuredAnchor _anchor(String patternId, String payload, {int row = 2}) =>
    StructuredAnchor(
      patternId: patternId,
      payload: payload,
      ranges: [
        HighlightRange(
          startRow: row,
          startCol: 0,
          endRow: row,
          endCol: payload.length,
          payload: payload,
        ),
      ],
    );

/// Minimal fake controller for the gutter layer (mirrors the #955 test's).
class _FakeController extends ChangeNotifier implements TerminalController {
  List<StructuredAnchor> _anchors = const [];

  void setAnchors(List<StructuredAnchor> value) {
    _anchors = value;
    notifyListeners();
  }

  @override
  List<StructuredAnchor> get anchors => _anchors;

  @override
  bool get isScrolling => false;

  @override
  Listenable get decorationListenable => this;

  @override
  int? anchorGutterRow(HighlightRange range) => range.topRow;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('#994 ghosttyFileUrlPath (pure classification by scheme)', () {
    test('a url-pattern file:// match yields the bare decoded path', () {
      expect(
        ghosttyFileUrlPath(_match(kGhosttyUrlPatternId, 'file:///etc/hosts')),
        '/etc/hosts',
      );
    });

    test('an osc8-pattern file:// match yields the bare decoded path '
        '(hostname authority stripped, percent-decoded)', () {
      expect(
        ghosttyFileUrlPath(
          _match(kGhosttyOsc8PatternId, 'file://fd-dev/home/dev/my%20doc.md'),
        ),
        '/home/dev/my doc.md',
      );
    });

    test('a web URL is NOT path-class', () {
      expect(
        ghosttyFileUrlPath(_match(kGhosttyUrlPatternId, 'https://example.com')),
        isNull,
      );
    });

    test('a path-pattern match is NOT reclassified here (it already has the '
        'path action set)', () {
      expect(
        ghosttyFileUrlPath(_match(kGhosttyPathPatternId, '/etc/hosts')),
        isNull,
      );
    });

    test('a malformed file:// payload is ignored (falls back to URL class)', () {
      expect(
        ghosttyFileUrlPath(_match(kGhosttyUrlPatternId, 'file://hostonly')),
        isNull,
      );
      expect(
        ghosttyFileUrlPath(_match(kGhosttyUrlPatternId, 'file:///bad%zz')),
        isNull,
      );
    });
  });

  group('#994 tap dispatch: file:// NAVIGATES, web URLs still copy', () {
    Future<(List<String> opened, List<String> copied, String? toast)> tap(
      StructuredMatch match,
    ) async {
      final opened = <String>[];
      final copied = <String>[];
      final toast = await ghosttyTapMatchAction(
        match,
        copy: (text) async {
          copied.add(text);
          return true;
        },
        openPath: (path) async {
          opened.add(path);
          return true;
        },
      );
      return (opened, copied, toast);
    }

    test('a file:// url match invokes openPath with the BARE path — never '
        'the clipboard, no toast (navigation is the feedback)', () async {
      final (opened, copied, toast) = await tap(
        _match(kGhosttyUrlPatternId, 'file:///etc/hosts'),
      );
      expect(opened, ['/etc/hosts']);
      expect(copied, isEmpty);
      expect(toast, isNull);
    });

    test('an OSC-8 file:// link navigates too (authority stripped)', () async {
      final (opened, copied, toast) = await tap(
        _match(kGhosttyOsc8PatternId, 'file://fd-dev/var/log/'),
      );
      expect(opened, ['/var/log/']);
      expect(copied, isEmpty);
      expect(toast, isNull);
    });

    test('a SINGLE-SEGMENT file:// URL still navigates: file:// anchors are '
        'URL-pattern matches, NOT path-pattern — the #990 single-segment '
        'suppression does not apply (an explicit file:// scheme is explicit '
        'intent, always shown/actionable)', () async {
      final (opened, copied, _) = await tap(
        _match(kGhosttyUrlPatternId, 'file:///etc'),
      );
      expect(opened, ['/etc']);
      expect(copied, isEmpty);
    });

    test('a web URL match still tap-copies (unchanged #988)', () async {
      final (opened, copied, toast) = await tap(
        _match(kGhosttyUrlPatternId, 'https://example.com'),
      );
      expect(copied, ['https://example.com']);
      expect(opened, isEmpty);
      expect(toast, 'Copied URL');
    });

    test('a MALFORMED file:// payload falls back to the URL copy branch', () async {
      final (opened, copied, toast) = await tap(
        _match(kGhosttyUrlPatternId, 'file://hostonly'),
      );
      expect(opened, isEmpty);
      expect(copied, ['file://hostonly']);
      expect(toast, 'Copied URL');
    });
  });

  group('#994 path action menu with an sftp:// form', () {
    testWidgets('showPathActions with sftpUrl offers Open / Copy path / '
        'Copy sftp URL', (tester) async {
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
                  sftpUrl: 'sftp://testuser@10.0.0.5/etc/hosts',
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
      expect(find.byKey(const Key('path-action-open')), findsOneWidget);
      expect(find.byKey(const Key('path-action-copy')), findsOneWidget);
      expect(find.byKey(const Key('path-action-copy-sftp')), findsOneWidget);
      expect(find.text('Copy sftp URL'), findsOneWidget);
      debugDismissPathActions();
      await tester.pump();
    });

    testWidgets('without sftpUrl the menu is unchanged (no sftp action)', (
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
      expect(find.byKey(const Key('path-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('path-action-copy-sftp')), findsNothing);
      debugDismissPathActions();
      await tester.pump();
    });
  });

  group('#994 gutter registry routes file:// anchors to the PATH action set', () {
    Future<_FakeController> pumpLayer(
      WidgetTester tester, {
      Future<bool> Function(String path)? openPath,
      String? Function(String path)? sftpUrlOf,
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
                      sftpUrlOf: sftpUrlOf,
                    ),
                    color: const Color(0xFF5B9BD5),
                    cellHeight: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('tap a file:// URL mark → the PATH menu with the sftp action, '
        'not the URL menu', (tester) async {
      final controller = await pumpLayer(
        tester,
        sftpUrlOf: (path) => 'sftp://u@h$path',
      );
      controller.setAnchors([
        _anchor(kGhosttyUrlPatternId, 'file:///etc/hosts'),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-2')));
      await tester.pump();
      expect(find.byKey(const Key('path-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('url-action-menu')), findsNothing);
      expect(find.byKey(const Key('path-action-copy-sftp')), findsOneWidget);
      debugDismissPathActions();
    });

    testWidgets('tap an OSC-8 file:// mark → the PATH menu too', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _anchor(kGhosttyOsc8PatternId, 'file://fd-dev/etc/hosts'),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-2')));
      await tester.pump();
      expect(find.byKey(const Key('path-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('url-action-menu')), findsNothing);
      debugDismissPathActions();
    });

    testWidgets('a web URL mark keeps the URL menu (unchanged)', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _anchor(kGhosttyUrlPatternId, 'https://example.com'),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-2')));
      await tester.pump();
      expect(find.byKey(const Key('url-action-menu')), findsOneWidget);
      expect(find.byKey(const Key('path-action-menu')), findsNothing);
      debugDismissUrlActions();
    });

    testWidgets('the multi-match list sheet gives a file:// anchor Open / '
        'Copy path / Copy sftp URL and Open navigates with the BARE path', (
      tester,
    ) async {
      final opened = <String>[];
      final controller = await pumpLayer(
        tester,
        openPath: (path) async {
          opened.add(path);
          return true;
        },
        sftpUrlOf: (path) => 'sftp://u@h$path',
      );
      controller.setAnchors([
        _anchor(kGhosttyUrlPatternId, 'file:///etc/hosts', row: 6),
        _anchor(kGhosttyPathPatternId, '/var/log', row: 6),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-6')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gutter-pattern-list')), findsOneWidget);
      // The file:// row keeps its raw payload TITLE (what was detected) but
      // carries the three PATH-class actions.
      expect(find.text('file:///etc/hosts'), findsOneWidget);
      expect(find.byKey(const Key('gutter-item-0-open')), findsOneWidget);
      expect(find.byKey(const Key('gutter-item-0-copy')), findsOneWidget);
      expect(find.byKey(const Key('gutter-item-0-copy-sftp')), findsOneWidget);

      await tester.tap(find.byKey(const Key('gutter-item-0-open')));
      await tester.pumpAndSettle();
      expect(opened, ['/etc/hosts'], reason: 'Open must use the BARE path');
    });
  });
}
