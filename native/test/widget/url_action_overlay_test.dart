// URL action overlay (#570 "copy & navigate URLs" — Slice 1).
//
// Contract under test:
//   - long-press on a detected URL surfaces a Copy/Open menu,
//   - Copy puts the URL on the system clipboard + shows a top-toast confirmation,
//   - Open invokes the (injected, fake) launcher with the URL — NOT a real
//     browser,
//   - tap-outside dismisses the menu,
//   - a transient highlight is painted over the URL's cell rect(s).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/url_action_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'https://example.com/path';

  // Capture clipboard writes. The copy path now routes through the hardened
  // `mobissh/clipboard` native channel (#845), which then reads back via the
  // platform `Clipboard.getData`. Mock BOTH: the native channel records the
  // write, the platform channel serves the read-back from the same store.
  String? lastClipboard;

  setUp(() {
    lastClipboard = null;
    debugUrlOpenerOverride = null;
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
    debugUrlOpenerOverride = null;
  });

  // Drain any live overlay + toast timers at the END of a test body (before the
  // framework's "Timer still pending" invariant runs, which `addTearDown` is too
  // late for). Dismiss the menu, then pump past the top-toast's auto-dismiss.
  Future<void> settle(WidgetTester tester) async {
    debugDismissUrlActions();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpAndShow(
    WidgetTester tester, {
    List<Rect> rects = const [Rect.fromLTWH(40, 40, 120, 18)],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showUrlActions(
                  context,
                  url,
                  highlightRects: rects,
                  anchor: const Offset(100, 50),
                ),
                child: const Text('fire'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('fire'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('shows the Copy/Open menu', (tester) async {
    await pumpAndShow(tester);
    expect(find.byKey(const Key('url-action-menu')), findsOneWidget);
    expect(find.byKey(const Key('url-action-copy')), findsOneWidget);
    expect(find.byKey(const Key('url-action-open')), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('Copy puts the URL on the clipboard + confirms via top-toast', (
    tester,
  ) async {
    await pumpAndShow(tester);
    await tester.tap(find.byKey(const Key('url-action-copy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(lastClipboard, url);
    // Confirmation surfaces as a top-toast (not a bottom SnackBar).
    expect(find.byKey(const Key('top-toast')), findsOneWidget);
    // Menu is dismissed after the action.
    expect(find.byKey(const Key('url-action-menu')), findsNothing);
    await settle(tester);
  });

  testWidgets('Open invokes the injected launcher with the URL', (
    tester,
  ) async {
    String? opened;
    debugUrlOpenerOverride = (u) async {
      opened = u;
      return true;
    };
    await pumpAndShow(tester);
    await tester.tap(find.byKey(const Key('url-action-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(opened, url, reason: 'Open should call the launcher with the URL');
    expect(find.byKey(const Key('url-action-menu')), findsNothing);
    await settle(tester);
  });

  testWidgets('Open failure shows an error top-toast', (tester) async {
    debugUrlOpenerOverride = (u) async => false;
    await pumpAndShow(tester);
    await tester.tap(find.byKey(const Key('url-action-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('top-toast')), findsOneWidget);
    expect(find.textContaining('Could not open'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('tap-outside dismisses the menu', (tester) async {
    await pumpAndShow(tester);
    expect(find.byKey(const Key('url-action-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('url-action-scrim')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('url-action-menu')), findsNothing);
    await settle(tester);
  });

  testWidgets('paints a highlight (CustomPaint present)', (tester) async {
    await pumpAndShow(
      tester,
      rects: const [
        Rect.fromLTWH(40, 40, 120, 18),
        Rect.fromLTWH(40, 58, 80, 18),
      ],
    );
    // The overlay includes a CustomPaint for the highlight rects.
    expect(
      find.descendant(
        of: find.byType(IgnorePointer),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
    await settle(tester);
  });
}
