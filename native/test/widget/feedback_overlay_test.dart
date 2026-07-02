// Widget tests for the app-wide in-app feedback affordance (#661).
//
// Locks the #661 contract:
//   1. The top-center affordance MOUNTS over whatever screen is showing.
//   2. Tapping it opens the comment sheet with a MULTI-LINE TextField.
//   3. Typing a long multi-line note + Submit calls the submitter with the
//      FULL comment (untruncated) — the data-loss bug #661 exists to fix.
//
// The submitter and version resolver are injected so the test runs with no
// network and no platform channels.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/ui/feedback_overlay.dart';

class _RecordingSubmitter implements FeedbackSubmitter {
  Map<String, Object?>? lastPayload;
  bool returnValue = true;

  @override
  Future<bool> submit(Map<String, Object?> payload) async {
    lastPayload = payload;
    return returnValue;
  }
}

// Fake capturer: bypasses RenderRepaintBoundary.toImage (which does not
// complete under the default test binding). Returns a couple of bytes so the
// payload carries a screenshot data URL.
Future<Uint8List> _fakeCapturer(GlobalKey key, double dpr) async {
  return Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
}

// Mirrors PRODUCTION wiring (main.dart): the overlay is mounted via
// `MaterialApp.builder`, i.e. ABOVE the Navigator — NOT inside `home` below it.
// This is the configuration that exposed the "just blinks" bug (the overlay's
// own context has no Navigator ancestor). The keys give it a below-Navigator
// context to show the sheet + confirmation from.
Widget _harness({
  required FeedbackSubmitter submitter,
  ScreenshotCapturer? capturer,
}) {
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  return MaterialApp(
    navigatorKey: navigatorKey,
    scaffoldMessengerKey: messengerKey,
    builder: (context, child) => FeedbackOverlay(
      navigatorKey: navigatorKey,
      messengerKey: messengerKey,
      submitter: submitter,
      versionResolver: () async => '[1.0.0+9 deadbee]',
      screenshotCapturer: capturer ?? _fakeCapturer,
      child: child ?? const SizedBox.shrink(),
    ),
    home: const Scaffold(body: Center(child: Text('SOME SCREEN CONTENT'))),
  );
}

void main() {
  testWidgets('feedback affordance mounts over the current screen', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('feedback-affordance')), findsOneWidget);
    // It floats OVER the screen content, which is still present.
    expect(find.text('SOME SCREEN CONTENT'), findsOneWidget);
  });

  testWidgets('tapping the affordance opens a multi-line comment sheet', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('feedback-comment-field')), findsOneWidget);
    expect(find.byKey(const Key('feedback-submit-button')), findsOneWidget);

    // The field is genuinely multi-line (no single-line cap that would clip a
    // long note).
    final field = tester.widget<TextField>(
      find.byKey(const Key('feedback-comment-field')),
    );
    expect(field.maxLines == null || field.maxLines! > 1, isTrue);
    expect(
      field.maxLength,
      isNull,
      reason: 'NO maxLength — full comment (#661)',
    );
  });

  testWidgets('submitting sends the FULL multi-line comment to the submitter', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();

    const longNote =
        'First line that would have been the truncated title and then a lot '
        'more text that the web form lost.\nSecond line.\nThird line trailing.';
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      longNote,
    );
    await tester.pump();

    await tester.ensureVisible(
      find.byKey(const Key('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(submitter.lastPayload, isNotNull);
    expect(submitter.lastPayload!['comment'], longNote);
    // Untruncated: the trailing line survived.
    expect(
      (submitter.lastPayload!['comment'] as String).contains('Third line'),
      isTrue,
    );
    expect(submitter.lastPayload!['version'], '[1.0.0+9 deadbee]');
  });

  testWidgets(
    'bundles the connect-trace ring (CTRACE659) into the submission',
    (tester) async {
      // The telemetry fix: a report submitted after a connect must carry the
      // connect log so the first-connect fill bug is fixable from DATA, not a
      // bounced build. The ring is a module global — clear it for isolation.
      clearConnectLog();
      ctrace('ui.fit659', 'connect: arming fit burst (shell ready)');
      ctrace(
        'ui.fit659',
        'burst-700ms: view=393.0x300.0 cell=8.4x18.0 computed=46x16 cur=46x16 '
            'noop font=JetBrainsMono settled=true',
      );

      final submitter = _RecordingSubmitter();
      await tester.pumpWidget(_harness(submitter: submitter));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('feedback-affordance')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('feedback-comment-field')),
        'first connect layout broken',
      );
      await tester.pump();
      await tester.ensureVisible(
      find.byKey(const Key('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
      await tester.pumpAndSettle();

      final log = (submitter.lastPayload!['connectLog'] as List).cast<String>();
      expect(log.length, 2);
      expect(log.any((l) => l.contains('view=393.0x300.0')), isTrue);
      clearConnectLog();
    },
  );

  testWidgets(
    'long-pressing RECORDS a burst of frames and attaches them to the report',
    (tester) async {
      var captures = 0;
      Future<Uint8List> countingCapturer(GlobalKey key, double dpr) async {
        captures++;
        return Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
      }

      final submitter = _RecordingSubmitter();
      await tester.pumpWidget(
        _harness(submitter: submitter, capturer: countingCapturer),
      );
      await tester.pumpAndSettle();

      // Long-press starts the burst; the pill flips to a REC indicator.
      await tester.longPress(find.byKey(const Key('feedback-affordance')));
      await tester.pump();
      expect(find.byKey(const Key('feedback-recording')), findsOneWidget);

      // Advance through the ~10s window (200ms interval) — drive explicit pumps
      // (NOT pumpAndSettle, which would spin on the active recording loop).
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle();

      // It captured MANY frames during the window (not just one).
      expect(captures, greaterThan(5));
      // The comment sheet opened after the burst finished.
      expect(find.byKey(const Key('feedback-comment-field')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('feedback-comment-field')),
        'here is the wrapped-URL repro',
      );
      await tester.pump();
      await tester.ensureVisible(
      find.byKey(const Key('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
      await tester.pumpAndSettle();

      // The payload carries the frame burst as data URLs (capped at 50).
      final frames = submitter.lastPayload!['frames'] as List;
      expect(frames.length, greaterThan(5));
      expect(frames.length, lessThanOrEqualTo(50));
      expect(
        (frames.first as String).startsWith('data:image/png;base64,'),
        isTrue,
      );
      // A single tap still produces a one-shot screenshot and NO frames.
    },
  );

  testWidgets('a single TAP still sends one screenshot and NO frames', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      'single shot',
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(submitter.lastPayload!.containsKey('frames'), isFalse);
    expect(submitter.lastPayload!.containsKey('screenshot'), isTrue);
  });

  // ── #967: pre-send Review & Send consent gate ──────────────────────────────

  testWidgets('Cancel sends nothing (the egress is never called)', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      'changed my mind',
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('feedback-cancel-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-cancel-button')));
    await tester.pumpAndSettle();

    expect(
      submitter.lastPayload,
      isNull,
      reason: 'Cancel must not submit anything',
    );
  });

  testWidgets('excluding screen images omits the screenshot from the payload', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      'no screenshot please',
    );
    await tester.pump();
    // Toggle OFF the "include screen images" switch, then Send.
    await tester.ensureVisible(
      find.byKey(const Key('feedback-include-images')),
    );
    await tester.tap(find.byKey(const Key('feedback-include-images')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(submitter.lastPayload, isNotNull);
    expect(
      submitter.lastPayload!.containsKey('screenshot'),
      isFalse,
      reason: 'excluded image must be absent from the assembled payload',
    );
    // The note still goes.
    expect(submitter.lastPayload!['comment'], 'no screenshot please');
  });

  testWidgets('excluding traces omits the connect log from the payload', (
    tester,
  ) async {
    clearConnectLog();
    ctrace('ui.fit659', 'diagnostic line that would ship by default');

    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      'no traces please',
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('feedback-include-traces')),
    );
    await tester.tap(find.byKey(const Key('feedback-include-traces')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('feedback-submit-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(
      submitter.lastPayload!.containsKey('connectLog'),
      isFalse,
      reason: 'excluded traces must be absent from the assembled payload',
    );
    clearConnectLog();
  });

  testWidgets('a burst shows a scrubbable frame preview in the review sheet', (
    tester,
  ) async {
    Future<Uint8List> capturer(GlobalKey key, double dpr) async =>
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter, capturer: capturer));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('feedback-affordance')));
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();

    // The review sheet shows the motion-frame scrubber + counter + preview.
    expect(find.byKey(const Key('feedback-frame-scrubber')), findsOneWidget);
    expect(find.byKey(const Key('feedback-frame-counter')), findsOneWidget);
    expect(find.byKey(const Key('feedback-preview-image')), findsOneWidget);
  });
}
