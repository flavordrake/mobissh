// #998 slices C+D — the COMMAND-LINE gutter chip.
//
// A command anchor (the fork's block-tier TextPattern.command, slices A/B) gets
// a GUTTER-ONLY affordance: an Icons.terminal chip on the anchor's FIRST
// visible row (the gutter's existing anchorGutterRow semantics — never one chip
// per wrapped row). Single tap = COPY the whole command payload paste-exact
// (the existing copy toast); a multi-match row's list sheet labels the action
// "Copy command" and carries the LAST item "Not a command" (#995 exception
// store, family 'command'). Inner URL/path anchors keep their own affordances
// alongside — the block never fights the spans.
//
// Also locks the registration gating: `ghosttyDetectionPatterns` registers the
// command pattern only while the "Detect command lines" setting (AND the
// master switch) is on.
//
// No FFI: the fake controller supplies scripted anchors (the same harness as
// ghostty_gutter_layer_test.dart). Real-prompt detection + wrap-join payload
// exactness are the fork's slice-B tests + the emulator integration test.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

/// The paste-exact payload contract: internal quoting AND double spacing must
/// survive verbatim (the design's `bash  -s` case).
const _command =
    'curl -fsSL https://example.com/setup.sh | bash  -s "reset" >log 2>&1';
const _innerUrl = 'https://example.com/setup.sh';

StructuredAnchor _commandAnchor({List<int> rows = const [3]}) =>
    StructuredAnchor(
      patternId: kGhosttyCommandPatternId,
      payload: _command,
      ranges: [
        for (final r in rows)
          HighlightRange(
            startRow: r,
            startCol: 0,
            endRow: r,
            endCol: 20,
            payload: _command,
          ),
      ],
    );

StructuredAnchor _urlAnchor({int row = 3}) => StructuredAnchor(
  patternId: kGhosttyUrlPatternId,
  payload: _innerUrl,
  ranges: [
    HighlightRange(
      startRow: row,
      startCol: 6,
      endRow: row,
      endCol: 6 + _innerUrl.length,
      payload: _innerUrl,
    ),
  ],
);

/// Fake controller exposing scripted [anchors] + [anchorGutterRow] — the only
/// surface [GhosttyGutterLayer] reads (mirrors ghostty_gutter_layer_test.dart).
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
  int? anchorGutterRow(HighlightRange range) {
    final row = range.topRow;
    if (row < 0 || row >= 24) return null;
    return row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Capture clipboard writes: the copy path routes through the hardened
  // `mobissh/clipboard` channel (#845) with a platform-channel fallback.
  String? lastClipboard;

  setUp(() {
    lastClipboard = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      (call) async {
        if (call.method == 'setText') {
          lastClipboard = (call.arguments as Map)['text'] as String?;
          return true;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        lastClipboard = (call.arguments as Map)['text'] as String?;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': lastClipboard};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Drain the top-toast auto-dismiss timer before the test body ends.
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('registration gating (ghosttyDetectionPatterns, #998 C)', () {
    test('all-on registers osc8+url+path+command', () {
      final ids = ghosttyDetectionPatterns(const DetectionSettings())
          .map((p) => p.id)
          .toList();
      expect(ids, containsAll(<String>['osc8', 'url', 'path', 'command']));
    });

    test('the command pattern id matches the fork factory default', () {
      expect(kGhosttyCommandPatternId, TextPattern.command().id);
    });

    test('command toggle OFF removes ONLY the command registration', () {
      final ids = ghosttyDetectionPatterns(
        const DetectionSettings(command: false),
      ).map((p) => p.id).toList();
      expect(ids, isNot(contains('command')));
      expect(ids, containsAll(<String>['osc8', 'url', 'path']));
    });

    test('master OFF registers nothing', () {
      expect(
        ghosttyDetectionPatterns(const DetectionSettings(enabled: false)),
        isEmpty,
      );
    });

    test('the registered command pattern is BLOCK tier (gutter-only)', () {
      final command = ghosttyDetectionPatterns(const DetectionSettings())
          .firstWhere((p) => p.id == kGhosttyCommandPatternId);
      expect(command.tier, TextTier.block);
    });

    test('#1031 slice 2: a custom command LEXICON reaches the fork pattern '
        '(weak prompt discriminates)', () {
      // Weak `$ ` prompt + unknown first token: default lexicon scores 2
      // (flag + operator, no hit) → suppressed; a lexicon containing the
      // token scores 4 with the hit → detected.
      const line = r'$ frobnicate --deep | sort';
      final byDefault = ghosttyDetectionPatterns(const DetectionSettings())
          .firstWhere((p) => p.id == kGhosttyCommandPatternId);
      expect(byDefault.normalize!(line), isNull);

      final byCustom = ghosttyDetectionPatterns(
        const DetectionSettings(),
        commandLexicon: const ['frobnicate'],
      ).firstWhere((p) => p.id == kGhosttyCommandPatternId);
      expect(byCustom.normalize!(line), 'frobnicate --deep | sort');
    });
  });

  group('command gutter chip (#998 C)', () {
    Future<_FakeController> pumpLayer(
      WidgetTester tester, {
      void Function(String patternId, String payload)? onReportException,
      bool Function(StructuredAnchor anchor)? isVisible,
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
                      onReportException: onReportException,
                    ),
                    color: const Color(0xFF5B9BD5),
                    cellHeight: 20,
                    isVisible: isVisible,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('a command anchor row shows the terminal chip', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_commandAnchor(rows: const [5])]);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-5')), findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('gutter-mark-5')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, Icons.terminal);
    });

    testWidgets('a MULTI-ROW command anchor chips only its FIRST row',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _commandAnchor(rows: const [4, 5, 6]),
      ]);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-4')), findsOneWidget);
      expect(find.byKey(const Key('gutter-mark-5')), findsNothing);
      expect(find.byKey(const Key('gutter-mark-6')), findsNothing);
    });

    testWidgets('tap the command chip → copies the EXACT payload + toast',
        (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([_commandAnchor(rows: const [5])]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-5')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        lastClipboard,
        _command,
        reason: 'the copy must be paste-exact (quotes, redirects, double '
            'space preserved verbatim)',
      );
      // The existing copy toast — and NO url/path action overlay.
      expect(find.textContaining('Copied'), findsOneWidget);
      expect(find.byKey(const Key('url-action-menu')), findsNothing);
      expect(find.byKey(const Key('path-action-menu')), findsNothing);
      await drainToast(tester);
    });

    testWidgets(
        'command + inner URL on one row → list sheet: "Copy command" copies '
        'the whole command; the URL item copies just the URL', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _commandAnchor(rows: const [3]),
        _urlAnchor(row: 3),
      ]);
      await tester.pump();

      // Both anchors share the row → the count badge, not two chips.
      expect(find.byKey(const Key('gutter-mark-3')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('gutter-mark-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gutter-pattern-list')), findsOneWidget);
      // Item 0 is the command (anchor order): labeled clearly.
      expect(find.text('Command'), findsOneWidget);
      final copyCommand = find.byKey(const Key('gutter-item-0-copy'));
      expect(
        tester.widget<IconButton>(copyCommand).tooltip,
        'Copy command',
        reason: 'the sheet must label the whole-command copy clearly',
      );
      await tester.tap(copyCommand);
      await tester.pumpAndSettle();
      expect(lastClipboard, _command);

      // Re-open: the URL item's copy still copies JUST the URL.
      await tester.tap(find.byKey(const Key('gutter-mark-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('gutter-item-1-copy')));
      await tester.pumpAndSettle();
      expect(lastClipboard, _innerUrl);
      await drainToast(tester);
    });

    testWidgets(
        'the inner URL keeps its OWN chip on its own row beside a wrapped '
        'command block', (tester) async {
      final controller = await pumpLayer(tester);
      controller.setAnchors([
        _commandAnchor(rows: const [3, 4]),
        _urlAnchor(row: 4),
      ]);
      await tester.pump();
      // Command chips row 3; the URL (starting on the wrap row) chips row 4.
      final commandIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('gutter-mark-3')),
          matching: find.byType(Icon),
        ),
      );
      final urlIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('gutter-mark-4')),
          matching: find.byType(Icon),
        ),
      );
      expect(commandIcon.icon, Icons.terminal);
      expect(urlIcon.icon, Icons.link);
    });

    testWidgets('"Not a command" is the LAST sheet action and reports the '
        'command patternId + exact payload (#998 D)', (tester) async {
      final reports = <(String, String)>[];
      final controller = await pumpLayer(
        tester,
        onReportException: (patternId, payload) =>
            reports.add((patternId, payload)),
      );
      controller.setAnchors([
        _commandAnchor(rows: const [3]),
        _urlAnchor(row: 3),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const Key('gutter-mark-3')));
      await tester.pumpAndSettle();

      final notCommand = find.byKey(const Key('gutter-item-0-not'));
      expect(tester.widget<IconButton>(notCommand).tooltip, 'Not a command');
      // LAST action on the command item: no other action follows it in the row.
      final commandActions = tester
          .widgetList<IconButton>(
            find.descendant(
              of: find.byKey(const Key('gutter-item-0')),
              matching: find.byType(IconButton),
            ),
          )
          .toList();
      expect(commandActions.last.tooltip, 'Not a command');

      await tester.tap(notCommand);
      await tester.pumpAndSettle();
      expect(reports, [(kGhosttyCommandPatternId, _command)]);
      await drainToast(tester);
    });

    testWidgets('a suppressed command anchor renders NO chip (the #995/#990 '
        'visibility seam)', (tester) async {
      final controller = await pumpLayer(
        tester,
        isVisible: (a) => '${a.payload}' != _command,
      );
      controller.setAnchors([_commandAnchor(rows: const [5])]);
      await tester.pump();
      expect(find.byKey(const Key('gutter-mark-5')), findsNothing);
    });

    // #1042 — the maybeIncomplete honesty affordances: the chip renders an
    // ellipsis-marked variant (same size), the copy toast says so, and the
    // multi-match sheet carries a one-line note. No modals.
    group('maybeIncomplete affordances (#1042)', () {
      StructuredAnchor incompleteAnchor({List<int> rows = const [5]}) =>
          StructuredAnchor(
            patternId: kGhosttyCommandPatternId,
            payload: _command,
            maybeIncomplete: true,
            ranges: [
              for (final r in rows)
                HighlightRange(
                  startRow: r,
                  startCol: 0,
                  endRow: r,
                  endCol: 20,
                  payload: _command,
                ),
            ],
          );

      testWidgets('an incomplete command anchor renders the ellipsis chip '
          'variant', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([incompleteAnchor(rows: const [5])]);
        await tester.pump();
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('gutter-mark-5')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.icon, kGutterIncompleteIcon,
            reason: 'the incomplete variant is the ellipsis-marked glyph');
        expect(icon.icon, isNot(Icons.terminal));
        expect(icon.size, GutterMarkStyle.normal.glyphSize,
            reason: 'same size as the normal chip glyph');
      });

      testWidgets('tap the incomplete chip → copies the payload, toast reads '
          '"Copied — may be incomplete"', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([incompleteAnchor(rows: const [5])]);
        await tester.pump();

        await tester.tap(find.byKey(const Key('gutter-mark-5')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(lastClipboard, _command,
            reason: 'the copy itself is unchanged — the toast is the hedge');
        expect(find.text('Copied — may be incomplete'), findsOneWidget);
        await drainToast(tester);
      });

      testWidgets('a COMPLETE command anchor keeps the normal toast text',
          (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([_commandAnchor(rows: const [5])]);
        await tester.pump();

        await tester.tap(find.byKey(const Key('gutter-mark-5')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(lastClipboard, _command);
        expect(find.textContaining('Copied:'), findsOneWidget);
        expect(find.textContaining('may be incomplete'), findsNothing);
        await drainToast(tester);
      });

      testWidgets('the multi-match sheet shows the one-line note and its '
          '"Copy command" toast hedges too', (tester) async {
        final controller = await pumpLayer(tester);
        controller.setAnchors([
          incompleteAnchor(rows: const [3]),
          _urlAnchor(row: 3),
        ]);
        await tester.pump();

        await tester.tap(find.byKey(const Key('gutter-mark-3')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('gutter-pattern-list')), findsOneWidget);
        expect(find.text('Command — may be incomplete'), findsOneWidget,
            reason: 'the sheet subtitle is the one-line note');

        await tester.tap(find.byKey(const Key('gutter-item-0-copy')));
        await tester.pumpAndSettle();
        expect(lastClipboard, _command);
        expect(find.text('Copied — may be incomplete'), findsOneWidget);
        await drainToast(tester);
      });
    });
  });
}
