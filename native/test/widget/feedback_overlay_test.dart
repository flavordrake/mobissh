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

Widget _harness({required FeedbackSubmitter submitter}) {
  return MaterialApp(
    home: Scaffold(
      body: FeedbackOverlay(
        submitter: submitter,
        versionResolver: () async => '[1.0.0+9 deadbee]',
        screenshotCapturer: _fakeCapturer,
        child: const Center(child: Text('SOME SCREEN CONTENT')),
      ),
    ),
  );
}

void main() {
  testWidgets('feedback affordance mounts over the current screen', (tester) async {
    final submitter = _RecordingSubmitter();
    await tester.pumpWidget(_harness(submitter: submitter));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('feedback-affordance')), findsOneWidget);
    // It floats OVER the screen content, which is still present.
    expect(find.text('SOME SCREEN CONTENT'), findsOneWidget);
  });

  testWidgets('tapping the affordance opens a multi-line comment sheet',
      (tester) async {
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
    expect(field.maxLength, isNull, reason: 'NO maxLength — full comment (#661)');
  });

  testWidgets('submitting sends the FULL multi-line comment to the submitter',
      (tester) async {
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

    await tester.tap(find.byKey(const Key('feedback-submit-button')));
    await tester.pumpAndSettle();

    expect(submitter.lastPayload, isNotNull);
    expect(submitter.lastPayload!['comment'], longNote);
    // Untruncated: the trailing line survived.
    expect((submitter.lastPayload!['comment'] as String).contains('Third line'),
        isTrue);
    expect(submitter.lastPayload!['version'], '[1.0.0+9 deadbee]');
  });
}
