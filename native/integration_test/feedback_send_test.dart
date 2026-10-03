// On-device bug-report send: a report filed while the relay is unreachable is
// SAVED, and sent exactly once when the relay is back (#1259 gap 2 + outbox).
//
// This drives the REAL overlay on the device (real screenshot rasterization,
// real package_info and settings reads) through a REAL file-backed
// FeedbackOutbox in the app's private documents dir, POSTing with the
// production `postFeedbackBody` over real sockets:
//
//   1. relay unreachable (a loopback port with nothing listening) → Send →
//      the sheet stays up with the note intact and says it was SAVED;
//      Retry and Share instead are offered; the outbox holds 1 report
//   2. the user just closes the sheet (does nothing else)
//   3. the relay comes back; a NEW outbox instance on the same dir (what a
//      relaunch's launch trigger runs: no in-memory state survives) flushes →
//      the relay receives the report with the note and screenshot
//   4. a second trigger sends nothing: delivered exactly once
//
// The relay is an in-process HTTP server on the device's loopback, a stand-in
// for server/index.js's /api/bug-report. Reaching the real relay from the
// fleet emulator would need a third adb-reverse bridge, which this test does
// not add. The server's own ingest is covered by test/infra.
//
// The overlay is pumped in a minimal MaterialApp (mounted via `builder`, the
// production wiring) rather than through MobisshApp, which constructs the
// overlay with the baked endpoint and offers no override seam.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobissh/diagnostics/feedback_outbox.dart';
import 'package:mobissh/ui/feedback_overlay.dart';

/// Pump until [done] holds or ~[slices]×[step] passes.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int slices = 40,
  Duration step = const Duration(milliseconds: 250),
}) async {
  for (var i = 0; i < slices; i++) {
    await tester.pump(step);
    if (done()) return true;
  }
  return false;
}

bool _present(Finder f) => f.evaluate().isNotEmpty;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offline report is saved, then sent exactly once (#1259)', (
    tester,
  ) async {
    // A port that was free a moment ago: connecting to it is refused.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close();

    final received = <Map<String, Object?>>[];
    final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      received.add(jsonDecode(body) as Map<String, Object?>);
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      await req.response.close();
    });
    addTearDown(() => relay.close(force: true));

    final docs = await getApplicationDocumentsDirectory();
    final outboxDir = Directory('${docs.path}/feedback-outbox-test-1259');
    if (await outboxDir.exists()) await outboxDir.delete(recursive: true);
    addTearDown(() async {
      if (await outboxDir.exists()) await outboxDir.delete(recursive: true);
    });

    var endpoint = 'http://127.0.0.1:$deadPort/api/bug-report';
    FeedbackOutbox newOutbox() => FeedbackOutbox(
      dir: () async => outboxDir,
      poster: (body) => postFeedbackBody(body, endpoint: endpoint),
    );

    final navigatorKey = GlobalKey<NavigatorState>();
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        builder: (context, child) => FeedbackOverlay(
          navigatorKey: navigatorKey,
          messengerKey: messengerKey,
          outbox: newOutbox(),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(
          body: Center(child: Text('FEEDBACK DEVICE TEST SCREEN')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('feedback-affordance')));
    expect(
      await _pumpUntil(
        tester,
        () => _present(find.byKey(const Key('feedback-comment-field'))),
      ),
      isTrue,
      reason: 'the review sheet did not open',
    );

    const note = 'device note filed offline, must arrive once #1259';
    await tester.enterText(
      find.byKey(const Key('feedback-comment-field')),
      note,
    );
    await tester.pump();
    // Hide the keyboard so the sheet's buttons are on screen.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));

    final send = find.byKey(const Key('feedback-submit-button'));
    await tester.ensureVisible(send);
    await tester.pump();
    await tester.tap(send);

    // 1. Unreachable relay → saved, persistent inline message, note intact.
    expect(
      await _pumpUntil(
        tester,
        () => _present(find.byKey(const Key('feedback-send-error'))),
      ),
      isTrue,
      reason: 'a refused connection must surface the inline message',
    );
    expect(received, isEmpty);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('feedback-send-error')), findsOneWidget);
    expect(
      find.textContaining('Saved — it will send automatically'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('feedback-comment-field')))
          .controller!
          .text,
      note,
    );
    expect(find.byKey(const Key('feedback-retry-button')), findsOneWidget);
    expect(
      find.byKey(const Key('feedback-share-instead-button')),
      findsOneWidget,
    );
    expect((await newOutbox().status()).pending, 1);

    // 2. The user does nothing more: Close.
    final close = find.byKey(const Key('feedback-cancel-button'));
    await tester.ensureVisible(close);
    await tester.pump();
    await tester.tap(close);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('feedback-comment-field')), findsNothing);

    // 3. Relay back; a fresh outbox (relaunch) runs the launch trigger.
    endpoint = 'http://127.0.0.1:${relay.port}/api/bug-report';
    final flushed = await newOutbox().flush();
    await tester.pump(const Duration(milliseconds: 500));
    expect(flushed.sent, 1);
    expect(received.length, 1);
    expect(received.single['comment'], note);
    expect(received.single['source'], 'native-in-app');
    expect(
      (received.single['screenshot'] as String?)?.startsWith(
        'data:image/png;base64,',
      ),
      isTrue,
      reason: 'the capture taken at filing time is what gets delivered',
    );

    // 4. Another trigger (connect / resume) finds nothing: exactly once.
    final again = await newOutbox().flush();
    await tester.pump(const Duration(milliseconds: 500));
    expect(again.sent, 0);
    expect(received.length, 1);
    expect((await newOutbox().status()).total, 0);
  });
}
