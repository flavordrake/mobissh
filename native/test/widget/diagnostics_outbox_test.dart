// #1259: bug reports saved while offline are visible in Settings → Advanced →
// Diagnostics with Send now / Discard — persistent, never a toast.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/feedback_outbox.dart';
import 'package:mobissh/ui/diagnostics_section.dart';

class _FakeOutbox implements FeedbackOutbox {
  OutboxStatus current = const OutboxStatus(pending: 2, rejected: 1);
  int flushes = 0;
  bool? lastAuto;
  int discards = 0;
  OutboxFlushResult flushResult = const OutboxFlushResult(sent: 2);

  @override
  Future<OutboxStatus> status() async => current;

  @override
  Future<OutboxFlushResult> flush({bool auto = true}) async {
    flushes++;
    lastAuto = auto;
    current = const OutboxStatus(rejected: 1);
    return flushResult;
  }

  @override
  Future<void> discardAll() async {
    discards++;
    current = const OutboxStatus();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_FakeOutbox outbox) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: DiagnosticsSection(outbox: outbox)),
  ),
);

void main() {
  testWidgets('shows the waiting count; Send now flushes regardless of backoff',
      (tester) async {
    final outbox = _FakeOutbox();
    await tester.pumpWidget(_host(outbox));
    await tester.pumpAndSettle();

    expect(find.text('2 bug reports waiting to send'), findsOneWidget);
    expect(find.textContaining('1 refused by the server'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('outbox-send-now')));
    await tester.pumpAndSettle();
    expect(outbox.flushes, 1);
    expect(outbox.lastAuto, isFalse, reason: 'a user tap ignores backoff');
    expect(find.text('0 bug reports waiting to send'), findsOneWidget);
    expect(find.textContaining('Sent 2'), findsOneWidget);
  });

  // #1271: reports older than 30 days are dropped; say so, like the cap.
  testWidgets('Send now reports saved reports that expired', (tester) async {
    final outbox = _FakeOutbox()
      ..flushResult = const OutboxFlushResult(sent: 1, expired: 1);
    await tester.pumpWidget(_host(outbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outbox-send-now')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('1 older than 30 days deleted'),
      findsOneWidget,
    );
  });

  testWidgets('Discard asks first, then empties the outbox', (tester) async {
    final outbox = _FakeOutbox();
    await tester.pumpWidget(_host(outbox));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('outbox-discard')));
    await tester.pumpAndSettle();
    expect(outbox.discards, 0, reason: 'nothing deleted before confirming');
    await tester.tap(find.byKey(const ValueKey('outbox-discard-confirm')));
    await tester.pumpAndSettle();
    expect(outbox.discards, 1);
    expect(find.byKey(const ValueKey('outbox-send-now')), findsNothing);
  });

  testWidgets('an empty outbox adds no row', (tester) async {
    final outbox = _FakeOutbox()..current = const OutboxStatus();
    await tester.pumpWidget(_host(outbox));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('outbox-row')), findsNothing);
  });
}
