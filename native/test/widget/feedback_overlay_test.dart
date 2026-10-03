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

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/diagnostics/feedback_outbox.dart';
import 'package:mobissh/ui/feedback_overlay.dart';

// In-memory stand-in for the file-backed outbox (its file I/O would not drain
// under testWidgets' fake clock; the outbox itself is covered by
// test/diagnostics/feedback_outbox_test.dart).
class _RecordingSubmitter implements FeedbackOutbox {
  Map<String, Object?>? lastPayload;
  bool returnValue = true;
  FeedbackPostOutcome? failOutcome;
  int calls = 0;
  int evictOnNext = 0;
  final List<String?> submittedIds = <String?>[];
  final List<String> discarded = <String>[];

  @override
  Future<OutboxSubmitResult> submit(String body, {String? id}) async {
    calls++;
    submittedIds.add(id);
    lastPayload = jsonDecode(body) as Map<String, Object?>;
    final evicted = evictOnNext;
    evictOnNext = 0;
    return OutboxSubmitResult(
      id: id ?? 'report-1',
      outcome: returnValue
          ? FeedbackPostOutcome.delivered
          : (failOutcome ?? FeedbackPostOutcome.failed),
      evicted: evicted,
    );
  }

  @override
  Future<void> discard(String id) async => discarded.add(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  required _RecordingSubmitter submitter,
  ScreenshotCapturer? capturer,
  Future<void> Function(String payloadJson)? sharer,
}) {
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  return MaterialApp(
    navigatorKey: navigatorKey,
    scaffoldMessengerKey: messengerKey,
    builder: (context, child) => FeedbackOverlay(
      navigatorKey: navigatorKey,
      messengerKey: messengerKey,
      outbox: submitter,
      versionResolver: () async => '[1.0.0+9 deadbee]',
      screenshotCapturer: capturer ?? _fakeCapturer,
      // #1257: a fixed snapshot; the production reader is a platform-backed
      // SharedPreferences future that the test clock does not drain.
      settingsSnapshotter: () async => const {'mobissh.ui.fontSize': 15.0},
      shareInstead: sharer ?? (_) async {},
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
    // #1257: the settings snapshot rides in the submitted payload.
    expect(submitter.lastPayload!['settings'], {'mobissh.ui.fontSize': 15.0});
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
      // Two planted ctrace lines + the #1135 frame-stats stamp the tap writes.
      expect(log.length, 3);
      expect(log.any((l) => l.contains('view=393.0x300.0')), isTrue);
      // #1135: EVERY report carries the frame-timing stamp inside the connect
      // ring — the ring is persisted today, so the numbers arrive whatever the
      // ingest end is running.
      expect(
        log.any((l) => l.contains('[frame-stats]') && l.contains('frames=')),
        isTrue,
        reason: 'the frame-stats stamp must ride in the connect log',
      );
      // #1135: and the structured section rides in the submitted payload, so a
      // reader gets the worst frames + the geometry, not just the summary.
      final stats =
          submitter.lastPayload!['frameStats']! as Map<String, Object?>;
      expect(stats.containsKey('frames'), isTrue);
      expect(stats.containsKey('p95Ms'), isTrue);
      expect(stats.containsKey('worst'), isTrue);
      expect(
        (stats['now']! as Map<String, Object?>)['viewport'],
        isA<Map<String, Object?>>(),
        reason: 'the viewport at capture time is the layout evidence',
      );
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

  // ── #1259 gap 2: a failed Send must never throw the report away ────────────

  Future<void> sendNote(WidgetTester tester, String note) async {
    await tester.tap(find.byKey(const Key('feedback-affordance')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      note,
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('feedback-submit-button')));
    await tester.tap(find.byKey(const Key('feedback-submit-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('a failed Send keeps the note and capture, with Retry + Share', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter()..returnValue = false;
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await sendNote(tester, 'relay is down but my note matters');
    expect(submitter.calls, 1);

    // The sheet is still up with every field intact.
    final field = tester.widget<TextField>(
      find.byKey(const Key('feedback-comment-field')),
    );
    expect(field.controller!.text, 'relay is down but my note matters');
    expect(find.byKey(const Key('feedback-preview-image')), findsOneWidget);

    // A persistent inline error with both actions — not a vanishing toast.
    expect(find.byKey(const Key('feedback-send-error')), findsOneWidget);
    expect(find.byKey(const Key('feedback-retry-button')), findsOneWidget);
    expect(
      find.byKey(const Key('feedback-share-instead-button')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const Key('feedback-send-error')), findsOneWidget);
    expect(find.byKey(const Key('feedback-comment-field')), findsOneWidget);
    // The outbox kept it: the user is told it will go out on its own.
    expect(
      find.textContaining('Saved — it will send automatically'),
      findsOneWidget,
    );
    expect(find.text('Close'), findsOneWidget, reason: 'closing keeps it');
  });

  testWidgets('a full outbox says the oldest saved report was dropped', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter()
      ..returnValue = false
      ..evictOnNext = 1;
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();
    await sendNote(tester, 'outbox full');
    expect(
      find.textContaining('oldest saved report was dropped'),
      findsOneWidget,
    );
  });

  testWidgets('a 401/403 rejection offers Share instead, not Retry', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter()
      ..returnValue = false
      ..failOutcome = FeedbackPostOutcome.rejected;
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();
    await sendNote(tester, 'wrong key build');
    expect(find.textContaining('server refused'), findsOneWidget);
    expect(find.byKey(const Key('feedback-retry-button')), findsNothing);
    expect(
      find.byKey(const Key('feedback-share-instead-button')),
      findsOneWidget,
    );
  });

  testWidgets('Retry re-submits the same report; success closes and confirms', (
    tester,
  ) async {
    final submitter = _RecordingSubmitter()..returnValue = false;
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    await sendNote(tester, 'retry me');
    final failedPayload = submitter.lastPayload!;

    submitter.returnValue = true;
    await tester.ensureVisible(find.byKey(const Key('feedback-retry-button')));
    await tester.tap(find.byKey(const Key('feedback-retry-button')));
    await tester.pump();
    await tester.pump();

    expect(submitter.calls, 2);
    expect(
      submitter.submittedIds,
      [null, 'report-1'],
      reason: 'Retry re-writes the SAME outbox entry — queued once',
    );
    expect(submitter.lastPayload!['comment'], 'retry me');
    expect(
      submitter.lastPayload!['screenshot'],
      failedPayload['screenshot'],
      reason: 'Retry sends the SAME capture, not a fresh one',
    );
    expect(find.text('Feedback sent — thanks!'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('feedback-comment-field')), findsNothing);
    expect(find.byKey(const Key('feedback-send-error')), findsNothing);
  });

  testWidgets('Share instead hands the full report to the bundle sharer', (
    tester,
  ) async {
    String? shared;
    final submitter = _RecordingSubmitter()..returnValue = false;
    await tester.pumpWidget(
      _harness(submitter: submitter, sharer: (json) async => shared = json),
    );
    await tester.pumpAndSettle();

    await sendNote(tester, 'share this offline');
    await tester.ensureVisible(
      find.byKey(const Key('feedback-share-instead-button')),
    );
    await tester.tap(find.byKey(const Key('feedback-share-instead-button')));
    await tester.pumpAndSettle();

    expect(shared, isNotNull);
    final decoded = jsonDecode(shared!) as Map<String, Object?>;
    expect(decoded['comment'], 'share this offline');
    expect(decoded.containsKey('screenshot'), isTrue);
    expect(submitter.calls, 1, reason: 'sharing does not re-submit');
    expect(
      submitter.discarded,
      ['report-1'],
      reason: 'shared by hand — not also auto-sent later',
    );
    expect(find.byKey(const Key('feedback-comment-field')), findsNothing);
  });
}
