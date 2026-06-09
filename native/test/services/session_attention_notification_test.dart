// Unit tests for the attention NOTIFICATION layer (#840, Slice 2).
//
// Covers the PURE pieces: AttentionSignal → notification mapping, the
// "no secret material" payload guarantee, the suppression predicate, the
// (win N) source-window parser, and the PendingFocusBridge consume→id flow.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/attention_signal_scanner.dart';
import 'package:mobissh/services/session_attention_notification.dart';

void main() {
  group('AttentionNotification.build', () {
    test('maps an OSC9 signal to title/body/tag/payload', () {
      const sig = AttentionSignal(AttentionKind.osc9, 'Claude — main (win 3)');
      final n = AttentionNotification.build(sessionId: 'sess-A', signal: sig);

      expect(n.title, kAttentionTitle);
      // (win N) is stripped from the visible body and structured into payload.
      expect(n.body, 'Claude — main');
      expect(n.tag, 'mobissh.attention.sess-A');
      expect(n.sourceWindow, 3);

      final payload = jsonDecode(n.payload) as Map;
      expect(payload['sessionId'], 'sess-A');
      expect(payload['sourceWindow'], 3);
    });

    test('per-session tag differs across sessions; same within a session', () {
      const sig = AttentionSignal(AttentionKind.osc9, 'ready');
      final a1 = AttentionNotification.build(sessionId: 'A', signal: sig);
      final a2 = AttentionNotification.build(sessionId: 'A', signal: sig);
      final b = AttentionNotification.build(sessionId: 'B', signal: sig);
      expect(a1.tag, a2.tag); // replace, not stack
      expect(a1.tag, isNot(b.tag)); // distinct sessions distinct tags
    });

    test('text-less bare bell gets a fixed fallback body, no sourceWindow', () {
      const sig = AttentionSignal(AttentionKind.bell, null);
      final n = AttentionNotification.build(sessionId: 'A', signal: sig);
      expect(n.body, isNotEmpty);
      expect(n.sourceWindow, isNull);
      final payload = jsonDecode(n.payload) as Map;
      expect(payload.containsKey('sourceWindow'), isFalse);
    });

    test('osc777 title:body text is carried as the body', () {
      const sig = AttentionSignal(AttentionKind.osc777, 'MobiSSH: build done');
      final n = AttentionNotification.build(sessionId: 'A', signal: sig);
      expect(n.body, 'MobiSSH: build done');
    });

    test('PAYLOAD CARRIES NO SECRET MATERIAL', () {
      // Even if the parsed text somehow contained secret-looking material, the
      // payload is strictly {sessionId, sourceWindow?} — the body text is NOT
      // in the payload. Assert the payload contains only the allowed keys and
      // no password/passphrase/key/host/user fields.
      const sig = AttentionSignal(
        AttentionKind.osc9,
        'password=hunter2 passphrase=secret (win 1)',
      );
      final n = AttentionNotification.build(sessionId: 'sess-A', signal: sig);
      final payload = jsonDecode(n.payload) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'sessionId', 'sourceWindow'});
      final lower = n.payload.toLowerCase();
      expect(lower.contains('hunter2'), isFalse);
      expect(lower.contains('password'), isFalse);
      expect(lower.contains('passphrase'), isFalse);
      expect(lower.contains('secret'), isFalse);
    });
  });

  group('parseSourceWindow', () {
    test('present: extracts N', () {
      expect(parseSourceWindow('Claude (win 2)'), 2);
      expect(parseSourceWindow('done (win 12)'), 12);
      expect(parseSourceWindow('x (WIN 4)'), 4); // case-insensitive
    });
    test('absent: null', () {
      expect(parseSourceWindow('Claude is waiting'), isNull);
      expect(parseSourceWindow(null), isNull);
      expect(parseSourceWindow(''), isNull);
    });
    test('malformed: null (skips silently)', () {
      expect(parseSourceWindow('(win)'), isNull);
      expect(parseSourceWindow('(win abc)'), isNull);
      expect(parseSourceWindow('win 3'), isNull); // no parens
      expect(parseSourceWindow('(window 3)'), isNull);
    });
  });

  group('shouldPostAttention suppression', () {
    test('active session AND foreground → suppress (no post)', () {
      expect(
        shouldPostAttention(
          signalSessionId: 'A',
          activeSessionId: 'A',
          foreground: true,
        ),
        isFalse,
      );
    });
    test('active session but BACKGROUNDED → post', () {
      expect(
        shouldPostAttention(
          signalSessionId: 'A',
          activeSessionId: 'A',
          foreground: false,
        ),
        isTrue,
      );
    });
    test('NON-active session while foreground → post', () {
      expect(
        shouldPostAttention(
          signalSessionId: 'B',
          activeSessionId: 'A',
          foreground: true,
        ),
        isTrue,
      );
    });
    test('no active session → post', () {
      expect(
        shouldPostAttention(
          signalSessionId: 'A',
          activeSessionId: null,
          foreground: true,
        ),
        isTrue,
      );
    });
  });

  group('PendingFocusBridge', () {
    test('consume a pending payload → sessionId + sourceWindow, then cleared', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final n = AttentionNotification.build(
        sessionId: 'sess-Z',
        signal: const AttentionSignal(AttentionKind.osc9, 'x (win 5)'),
      );
      await bridge.setPendingFromPayload(n.payload);

      final taken = await bridge.takePending();
      expect(taken.sessionId, 'sess-Z');
      expect(taken.sourceWindow, 5);

      // One-shot: a second take returns nothing.
      final again = await bridge.takePending();
      expect(again.sessionId, isNull);
    });

    test('a payload with no sessionId is a no-op', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(null);
      await bridge.setPendingFromPayload('{}');
      final taken = await bridge.takePending();
      expect(taken.sessionId, isNull);
    });

    test('readPending is non-destructive', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(
        jsonEncode({'sessionId': 'A', 'sourceWindow': 1}),
      );
      final r1 = await bridge.readPending();
      final r2 = await bridge.readPending();
      expect(r1.sessionId, 'A');
      expect(r2.sessionId, 'A'); // still there
    });
  });

  group('RecordingAttentionNotifier', () {
    test('records posts', () async {
      final notifier = RecordingAttentionNotifier();
      final n = AttentionNotification.build(
        sessionId: 'A',
        signal: const AttentionSignal(AttentionKind.osc9, 'hi'),
      );
      await notifier.post(n);
      expect(notifier.posted.single.tag, 'mobissh.attention.A');
    });
  });
}
