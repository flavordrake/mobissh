// Unit tests for the connect-trace ring buffer (#543).
//
// Exercises cap/ordering, listenable notification, and clear — all in the UI
// isolate against the in-memory buffer. No platform channels.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';

void main() {
  setUp(clearConnectLog);
  tearDown(clearConnectLog);

  test('ring buffer caps at capacity, dropping oldest and keeping newest', () {
    final n = connectLogCapacity;
    for (var i = 0; i < n + 10; i++) {
      ctrace('ui.test', 'line $i');
    }

    final lines = connectLog.value;
    expect(lines.length, n, reason: 'buffer must cap at $n');
    // Oldest 10 (line 0..9) dropped; newest retained at the end.
    expect(lines.first, contains('line 10'),
        reason: 'oldest lines should be dropped');
    expect(lines.last, contains('line ${n + 9}'),
        reason: 'newest line should be retained at the end');
  });

  test('lines are appended in call order, newest last', () {
    ctrace('ui.form', 'first');
    ctrace('ui.sessions', 'second');
    ctrace('ui.gw', 'third');

    final lines = connectLog.value;
    expect(lines.length, 3);
    expect(lines[0], contains('[ui.form] first'));
    expect(lines[1], contains('[ui.sessions] second'));
    expect(lines[2], contains('[ui.gw] third'));
  });

  test('line includes a HH:mm:ss.SSS timestamp and the where tag', () {
    ctrace('ui.proxy', 'hello');
    final line = connectLog.value.single;
    expect(line, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[ui\.proxy\] hello$')));
  });

  test('appending notifies listeners with a fresh list instance', () {
    var notifications = 0;
    void listener() => notifications++;
    connectLog.addListener(listener);
    addTearDown(() => connectLog.removeListener(listener));

    final before = connectLog.value;
    ctrace('ui.keepalive', 'ping');
    final after = connectLog.value;

    expect(notifications, 1, reason: 'a single append fires one notification');
    expect(identical(before, after), isFalse,
        reason: 'value must be a new list so ValueListenableBuilder rebuilds');
  });

  test('consecutive identical lines collapse into one with a ×N count', () {
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');

    final lines = connectLog.value;
    expect(lines.length, 1, reason: 'three identical lines collapse to one');
    expect(lines.single, contains('[ui.gw] recv output (×3)'));
  });

  test('a different line breaks the run and starts a fresh entry', () {
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'send input');
    ctrace('ui.gw', 'recv output'); // same text, but run was broken

    final lines = connectLog.value;
    expect(lines.length, 3);
    expect(lines[0], contains('[ui.gw] recv output (×2)'));
    expect(lines[1], contains('[ui.gw] send input'));
    expect(lines[1], isNot(contains('×')),
        reason: 'a single occurrence has no count suffix');
    expect(lines[2], contains('[ui.gw] recv output'));
    expect(lines[2], isNot(contains('×')));
  });

  test('collapsing notifies listeners so the count updates live', () {
    var notifications = 0;
    void listener() => notifications++;
    connectLog.addListener(listener);
    addTearDown(() => connectLog.removeListener(listener));

    ctrace('ui.gw', 'recv output');
    ctrace('ui.gw', 'recv output');

    expect(notifications, 2,
        reason: 'each call notifies, even when collapsing the line');
  });

  test('clearConnectLog empties the buffer and notifies', () {
    ctrace('ui.form', 'a');
    ctrace('ui.form', 'b');
    expect(connectLog.value, isNotEmpty);

    var cleared = false;
    void listener() => cleared = connectLog.value.isEmpty;
    connectLog.addListener(listener);
    addTearDown(() => connectLog.removeListener(listener));

    clearConnectLog();
    expect(connectLog.value, isEmpty);
    expect(cleared, isTrue);
  });
}
