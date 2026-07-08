// Widget contract for #995 "Not a URL" / "Not a file" detection exceptions.
//
// Asserts:
//   - the URL action overlay offers a 'Not a URL' item (LAST) when the caller
//     provides onMarkNotDetection; tapping fires the callback and dismisses
//   - the PATH action overlay offers 'Not a file' the same way
//   - neither overlay shows the item when no callback is provided (additive)
//   - the gutter registry's per-match list actions gain a LAST 'not' action per
//     anchor class ('Not a URL' for url payloads, 'Not a file' for path and
//     file:// payloads — the file:// report carries the ORIGINAL matched text)
//   - the Settings page lists persisted exceptions (text + host) with a
//     per-entry remove that restores detection

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/path_action_overlay.dart';
import 'package:mobissh/ui/settings_screen.dart';
import 'package:mobissh/ui/url_action_overlay.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> settleUrl(WidgetTester tester) async {
    debugDismissUrlActions();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> settlePath(WidgetTester tester) async {
    debugDismissPathActions();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpFire(WidgetTester tester, void Function(BuildContext) fire) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => fire(context),
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

  group('URL action overlay', () {
    testWidgets('offers Not a URL last; tap fires callback + dismisses', (
      tester,
    ) async {
      var reported = 0;
      await pumpFire(
        tester,
        (context) => showUrlActions(
          context,
          'https://example.com/x',
          highlightRects: const [Rect.fromLTWH(40, 40, 120, 18)],
          anchor: const Offset(100, 50),
          onMarkNotDetection: () => reported++,
        ),
      );

      final notItem = find.byKey(const Key('url-action-not-url'));
      expect(notItem, findsOneWidget);
      expect(find.text('Not a URL'), findsOneWidget);
      // Destructive-adjacent placement: LAST — after Copy and Open in reading
      // order (the Wrap may flow it to a second line).
      final notPos = tester.getTopLeft(notItem);
      final openPos = tester.getTopLeft(
        find.byKey(const Key('url-action-open')),
      );
      expect(
        notPos.dy > openPos.dy ||
            (notPos.dy == openPos.dy && notPos.dx > openPos.dx),
        isTrue,
        reason: 'Not a URL must be the last item in the menu',
      );

      await tester.tap(notItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(reported, 1);
      expect(find.byKey(const Key('url-action-menu')), findsNothing);
      await settleUrl(tester);
    });

    testWidgets('absent without a callback (additive)', (tester) async {
      await pumpFire(
        tester,
        (context) => showUrlActions(
          context,
          'https://example.com/x',
          highlightRects: const [],
          anchor: const Offset(100, 50),
        ),
      );
      expect(find.byKey(const Key('url-action-not-url')), findsNothing);
      await settleUrl(tester);
    });
  });

  group('Path action overlay', () {
    testWidgets('offers Not a file last; tap fires callback + dismisses', (
      tester,
    ) async {
      var reported = 0;
      await pumpFire(
        tester,
        (context) => showPathActions(
          context,
          '/etc/hosts',
          highlightRects: const [Rect.fromLTWH(40, 40, 120, 18)],
          anchor: const Offset(100, 50),
          onMarkNotDetection: () => reported++,
        ),
      );

      final notItem = find.byKey(const Key('path-action-not-file'));
      expect(notItem, findsOneWidget);
      expect(find.text('Not a file'), findsOneWidget);

      await tester.tap(notItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(reported, 1);
      expect(find.byKey(const Key('path-action-menu')), findsNothing);
      await settlePath(tester);
    });

    testWidgets('absent without a callback (additive)', (tester) async {
      await pumpFire(
        tester,
        (context) => showPathActions(
          context,
          '/etc/hosts',
          highlightRects: const [],
          anchor: const Offset(100, 50),
        ),
      );
      expect(find.byKey(const Key('path-action-not-file')), findsNothing);
      await settlePath(tester);
    });
  });

  group('Gutter registry list actions', () {
    ({String pattern, String payload})? reported;
    GutterPatternRegistry registry() {
      reported = null;
      return GutterPatternRegistry.standard(
        openPath: (_) async => true,
        onReportException: (patternId, payload) =>
            reported = (pattern: patternId, payload: payload),
      );
    }

    Future<BuildContext> pumpContext(WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      return ctx;
    }

    testWidgets('url payload gets a LAST Not a URL action', (tester) async {
      final reg = registry();
      final actions = reg.forPattern('url')!.itemActions('https://a.b/c');
      expect(actions.last.keyLabel, 'not');
      expect(actions.last.label, 'Not a URL');

      final ctx = await pumpContext(tester);
      await actions.last.onInvoke(ctx);
      expect(reported, isNotNull);
      expect(reported!.payload, 'https://a.b/c');
    });

    testWidgets('path payload gets a LAST Not a file action', (tester) async {
      final reg = registry();
      final actions = reg.forPattern('path')!.itemActions('/etc/hosts');
      expect(actions.last.keyLabel, 'not');
      expect(actions.last.label, 'Not a file');

      final ctx = await pumpContext(tester);
      await actions.last.onInvoke(ctx);
      expect(reported, isNotNull);
      expect(reported!.pattern, 'path');
      expect(reported!.payload, '/etc/hosts');
    });

    testWidgets('file:// payload reports the ORIGINAL matched text', (
      tester,
    ) async {
      final reg = registry();
      const fileUrl = 'file:///home/dev/notes.md';
      final actions = reg.forPattern('url')!.itemActions(fileUrl);
      expect(actions.last.keyLabel, 'not');
      expect(actions.last.label, 'Not a file');

      final ctx = await pumpContext(tester);
      await actions.last.onInvoke(ctx);
      expect(reported, isNotNull);
      expect(
        reported!.payload,
        fileUrl,
        reason: 'suppression matches the anchor payload, not the bare path',
      );
    });

    testWidgets('no report callback → no not action (additive)', (
      tester,
    ) async {
      final reg = GutterPatternRegistry.standard(openPath: (_) async => true);
      final actions = reg.forPattern('url')!.itemActions('https://a.b/c');
      expect(actions.where((a) => a.keyLabel == 'not'), isEmpty);
    });
  });

  group('Settings: Detection exceptions', () {
    Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
        ),
      );
      await _pumpFrames(tester);
      return container;
    }

    testWidgets('lists persisted exceptions with text + host', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final store = DetectionExceptionsStore(prefs: prefs);
      await store.add(
        DetectionException(
          matchedText: 'https://false.positive/x',
          patternId: 'url',
          host: 'test-sshd',
          tsMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final container = await pumpSettings(tester);
      expect(container.read(detectionExceptionsProvider), hasLength(1));

      expect(find.text('Detection exceptions'), findsOneWidget);
      expect(find.byKey(const ValueKey('detection-exception-0')), findsOneWidget);
      expect(find.text('https://false.positive/x'), findsOneWidget);
      expect(find.textContaining('test-sshd'), findsOneWidget);
    });

    testWidgets('empty state renders a hint, no entries', (tester) async {
      await pumpSettings(tester);
      expect(
        find.byKey(const ValueKey('detection-exceptions-empty')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('detection-exception-0')), findsNothing);
    });

    testWidgets('per-entry remove restores detection', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final store = DetectionExceptionsStore(prefs: prefs);
      await store.add(
        const DetectionException(matchedText: '/etc/hosts', patternId: 'path'),
      );

      final container = await pumpSettings(tester);
      final notifier = container.read(detectionExceptionsProvider.notifier);
      expect(notifier.isSuppressed('path', '/etc/hosts'), isTrue);

      await tester.tap(
        find.byKey(const ValueKey('detection-exception-remove-0')),
      );
      await _pumpFrames(tester);

      expect(find.byKey(const ValueKey('detection-exception-0')), findsNothing);
      expect(notifier.isSuppressed('path', '/etc/hosts'), isFalse);
      // Persisted: the store no longer has it either.
      expect(await store.load(), isEmpty);
    });
  });
}
