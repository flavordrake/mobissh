// On-device bug-report send: failure keeps the report, Retry delivers it
// (#1259 gap 2).
//
// The in-app feedback overlay is the one channel meant for reporting problems,
// and a failed Send used to throw the note and capture away behind a 2s toast.
// This drives the REAL overlay on the device — real screenshot rasterization,
// real package_info / settings reads, real HTTP through HttpFeedbackSubmitter —
// against two endpoints:
//
//   1. a loopback port with nothing listening (connection refused)
//      → the sheet stays up, the note is intact, the inline error shows Retry
//   2. an in-process HTTP relay on the device's loopback
//      → Retry delivers the SAME note + screenshot, the sheet closes
//
// The relay is a stand-in for server/index.js's /api/bug-report: reaching the
// real relay from the fleet emulator needs a third adb-reverse bridge, which
// this test deliberately does not add. What the stand-in proves is the app
// side — the real HTTP client path, the payload on the wire, the UI states.
// The server's own ingest is covered by test/infra.
//
// The overlay is pumped in a minimal MaterialApp (mounted via `builder`, the
// production wiring) rather than through MobisshApp, which constructs the
// overlay with the baked endpoint and offers no override seam.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/ui/feedback_overlay.dart';

class _SwitchableSubmitter implements FeedbackSubmitter {
  _SwitchableSubmitter(this.endpoint);
  String endpoint;
  int calls = 0;

  @override
  Future<bool> submit(Map<String, Object?> payload) {
    calls++;
    return HttpFeedbackSubmitter(endpoint: endpoint).submit(payload);
  }
}

/// Pump until [finder] matches or ~[slices]×[step] passes.
Future<bool> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int slices = 40,
  Duration step = const Duration(milliseconds: 250),
}) async {
  for (var i = 0; i < slices; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('failed Send keeps the note; Retry delivers it (#1259)', (
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

    final submitter = _SwitchableSubmitter(
      'http://127.0.0.1:$deadPort/api/bug-report',
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
          submitter: submitter,
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
      await _pumpUntil(tester, find.byKey(const Key('feedback-comment-field'))),
      isTrue,
      reason: 'the review sheet did not open',
    );

    const note = 'device note that must survive a failed send #1259';
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

    // 1. Unreachable relay → persistent inline error, note intact.
    expect(
      await _pumpUntil(tester, find.byKey(const Key('feedback-send-error'))),
      isTrue,
      reason: 'a refused connection must surface the inline send error',
    );
    expect(submitter.calls, 1);
    expect(received, isEmpty);
    // It stays — this is guidance the user acts on, not a toast.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('feedback-send-error')), findsOneWidget);
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

    // 2. Relay reachable → Retry sends the same report and the sheet closes.
    submitter.endpoint = 'http://127.0.0.1:${relay.port}/api/bug-report';
    final retry = find.byKey(const Key('feedback-retry-button'));
    await tester.ensureVisible(retry);
    await tester.pump();
    await tester.tap(retry);

    var landed = false;
    for (var i = 0; i < 40 && !landed; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      landed = received.isNotEmpty &&
          find.byKey(const Key('feedback-comment-field')).evaluate().isEmpty;
    }
    expect(landed, isTrue, reason: 'Retry did not deliver and close the sheet');
    expect(submitter.calls, 2);
    expect(received.single['comment'], note);
    expect(received.single['source'], 'native-in-app');
    expect(
      (received.single['screenshot'] as String?)?.startsWith(
        'data:image/png;base64,',
      ),
      isTrue,
      reason: 'the capture taken before the failure is what Retry sends',
    );
    expect(find.byKey(const Key('feedback-send-error')), findsNothing);
  });
}
