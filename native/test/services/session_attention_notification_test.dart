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
      // #847: body leads with the host label (differentiate by server).
      expect(n.body, 'sess-A — Claude — main');
      expect(n.tag, 'mobissh.attention.sess-A');
      expect(n.sourceWindow, 3);

      final payload = jsonDecode(n.payload) as Map;
      expect(payload['sessionId'], 'sess-A');
      expect(payload['sourceWindow'], 3);
    });

    test('per-HOST tag: same host → same tag (replace, not stack); '
        'different host → distinct tag (#847)', () {
      const sig = AttentionSignal(AttentionKind.osc9, 'ready');
      // Two DISTINCT sessions to the SAME host (different ports/nonces).
      final h1a = AttentionNotification.build(
        sessionId: 'fd-dev:22:user:111',
        signal: sig,
      );
      final h1b = AttentionNotification.build(
        sessionId: 'fd-dev:2222:user:222',
        signal: sig,
      );
      final h2 = AttentionNotification.build(
        sessionId: 'other-host:22:user:333',
        signal: sig,
      );
      expect(h1a.tag, h1b.tag,
          reason: 'same host → one tag → repeats REPLACE, not stack');
      expect(h1a.tag, isNot(h2.tag), reason: 'distinct hosts → distinct tags');
      expect(h1a.tag, 'mobissh.attention.fd-dev');
    });

    test('payload still carries the EXACT originating sessionId (tag is host)',
        () {
      const sig = AttentionSignal(AttentionKind.osc9, 'ready');
      final n = AttentionNotification.build(
        sessionId: 'fd-dev:2222:user:222',
        signal: sig,
      );
      final payload = jsonDecode(n.payload) as Map;
      expect(payload['sessionId'], 'fd-dev:2222:user:222');
    });

    test('text-less bare bell body is the host label (differentiate by server), '
        'no sourceWindow', () {
      const sig = AttentionSignal(AttentionKind.bell, null);
      final n = AttentionNotification.build(
        sessionId: 'fd-dev.tailbe5094.ts.net:22:user:1',
        signal: sig,
      );
      // #847: even a context-less bell names the server (short host label).
      expect(n.body, 'fd-dev');
      expect(n.sourceWindow, isNull);
      final payload = jsonDecode(n.payload) as Map;
      expect(payload.containsKey('sourceWindow'), isFalse);
    });

    test('body differentiates by server: distinct hosts → distinct bodies (#847)',
        () {
      const sig = AttentionSignal(AttentionKind.bell, null);
      final a = AttentionNotification.build(
        sessionId: 'fd-dev.tailbe5094.ts.net:22:u:1',
        signal: sig,
      );
      final b = AttentionNotification.build(
        sessionId: 'nv-dev.tailbe5094.ts.net:22:u:2',
        signal: sig,
      );
      expect(a.body, 'fd-dev');
      expect(b.body, 'nv-dev');
      expect(a.body, isNot(b.body),
          reason: 'two servers must never show identical notification text');
    });

    test('osc777 title:body text is carried as the body, host-prefixed', () {
      const sig = AttentionSignal(AttentionKind.osc777, 'MobiSSH: build done');
      final n = AttentionNotification.build(
        sessionId: 'fd-dev.tailbe5094.ts.net:22:u:1',
        signal: sig,
      );
      expect(n.body, 'fd-dev — MobiSSH: build done');
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

    test('PAYLOAD CARRIES NO SECRET MATERIAL even with a URL present (#710)', () {
      // A signal that carries BOTH a URL and secret-looking material: the URL is
      // extracted into the payload (intended), but no auth material leaks. The
      // payload keys stay a closed set of {sessionId, sourceWindow?, url?}.
      const sig = AttentionSignal(
        AttentionKind.osc9,
        'Build ready: https://example.com/app.apk password=hunter2 (win 2)',
      );
      final n = AttentionNotification.build(sessionId: 'sess-A', signal: sig);
      final payload = jsonDecode(n.payload) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'sessionId', 'sourceWindow', 'url'});
      expect(payload['url'], 'https://example.com/app.apk');
      final lower = n.payload.toLowerCase();
      expect(lower.contains('hunter2'), isFalse);
      expect(lower.contains('password'), isFalse);
    });
  });

  group('AttentionNotification URL extraction (#710)', () {
    test('build extracts the first http(s) URL into the payload', () {
      const sig = AttentionSignal(
        AttentionKind.osc777,
        'Build ready: https://example.com/app.apk',
      );
      final n = AttentionNotification.build(sessionId: 'sess-A', signal: sig);
      expect(n.url, 'https://example.com/app.apk');
      final payload = jsonDecode(n.payload) as Map;
      expect(payload['url'], 'https://example.com/app.apk');
      // The URL stays visible in the body (host-prefixed, unchanged).
      expect(n.body, 'sess-A — Build ready: https://example.com/app.apk');
    });

    test('http and https both match; first wins', () {
      const sig = AttentionSignal(
        AttentionKind.osc9,
        'see http://a.test/1 then https://b.test/2',
      );
      final n = AttentionNotification.build(sessionId: 's', signal: sig);
      expect(n.url, 'http://a.test/1');
    });

    test('no URL → no url field and no url payload key', () {
      const sig = AttentionSignal(AttentionKind.osc9, 'Claude is waiting');
      final n = AttentionNotification.build(sessionId: 'sess-A', signal: sig);
      expect(n.url, isNull);
      final payload = jsonDecode(n.payload) as Map;
      expect(payload.containsKey('url'), isFalse);
    });

    test('bare bell (no text) → no url', () {
      const sig = AttentionSignal(AttentionKind.bell, null);
      final n = AttentionNotification.build(sessionId: 'fd-dev:22:u:1', signal: sig);
      expect(n.url, isNull);
    });

    test('URL with a (win N) suffix: url extracted, body still strips the win', () {
      const sig = AttentionSignal(
        AttentionKind.osc9,
        'ready https://example.com/x (win 3)',
      );
      final n = AttentionNotification.build(sessionId: 'fd-dev:22:u:1', signal: sig);
      expect(n.url, 'https://example.com/x');
      expect(n.sourceWindow, 3);
      // (win 3) stripped from body; URL retained.
      expect(n.body, 'fd-dev — ready https://example.com/x');
      final payload = jsonDecode(n.payload) as Map;
      expect(payload['url'], 'https://example.com/x');
      expect(payload['sourceWindow'], 3);
    });

    test('parsePayload round-trips url', () {
      final payload = jsonEncode({
        'sessionId': 'A',
        'sourceWindow': 1,
        'url': 'https://example.com/y',
      });
      final parsed = AttentionNotification.parsePayload(payload);
      expect(parsed.sessionId, 'A');
      expect(parsed.sourceWindow, 1);
      expect(parsed.url, 'https://example.com/y');
    });

    test('parsePayload with no url → null url', () {
      final parsed =
          AttentionNotification.parsePayload(jsonEncode({'sessionId': 'A'}));
      expect(parsed.url, isNull);
    });
  });

  group('parseUrl trailing-punctuation trim (#710)', () {
    test('trims a trailing close-paren + period', () {
      expect(parseUrl('see (https://x.com/p).'), 'https://x.com/p');
    });
    test('trims trailing sentence punctuation', () {
      expect(parseUrl('ready https://x.com/p,'), 'https://x.com/p');
      expect(parseUrl('ready https://x.com/p!'), 'https://x.com/p');
      expect(parseUrl('done: https://x.com/path;'), 'https://x.com/path');
    });
    test('keeps interior path characters', () {
      expect(parseUrl('https://x.com/a/b?q=1&z=2'), 'https://x.com/a/b?q=1&z=2');
    });
    test('first http(s) URL only; ignores bare www / non-http schemes', () {
      expect(parseUrl('go to www.example.com'), isNull);
      expect(parseUrl('ftp://example.com/x'), isNull);
      expect(parseUrl('no url here'), isNull);
      expect(parseUrl(null), isNull);
      expect(parseUrl(''), isNull);
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

  group('hostOfSessionId (#847)', () {
    test('parses host from host:port:user:nonce', () {
      expect(hostOfSessionId('fd-dev:22:user:1781037380521'), 'fd-dev');
      expect(hostOfSessionId('127.0.0.1:2223:testuser:999'), '127.0.0.1');
    });
    test('no colon → whole id (defensive)', () {
      expect(hostOfSessionId('synthetic-id'), 'synthetic-id');
    });
    test('leading colon → whole id (degrades safely)', () {
      expect(hostOfSessionId(':22:user:1'), ':22:user:1');
    });
  });

  group('shouldPostAttention HOST-LEVEL suppression (#847)', () {
    // sessions A and B are DIFFERENT sessions to the SAME host (fd-dev);
    // session C is to a DIFFERENT host.
    const sessA = 'fd-dev:22:user:111';
    const sessB = 'fd-dev:2222:user:222';
    const sessC = 'other:22:user:333';

    test('foreground + SAME host (same session) → suppress', () {
      expect(
        shouldPostAttention(
          signalSessionId: sessA,
          activeSessionId: sessA,
          activeHost: 'fd-dev',
          foreground: true,
        ),
        isFalse,
      );
    });
    test('foreground + SAME host (DIFFERENT session to that host) → suppress', () {
      // Looking at session B (same host) while session A bells → suppress.
      expect(
        shouldPostAttention(
          signalSessionId: sessA,
          activeSessionId: sessB,
          activeHost: 'fd-dev',
          foreground: true,
        ),
        isFalse,
      );
    });
    test('foreground + DIFFERENT host → fire', () {
      expect(
        shouldPostAttention(
          signalSessionId: sessC,
          activeSessionId: sessA,
          activeHost: 'fd-dev',
          foreground: true,
        ),
        isTrue,
      );
    });
    test('BACKGROUNDED → always fire (even same host)', () {
      expect(
        shouldPostAttention(
          signalSessionId: sessA,
          activeSessionId: sessA,
          activeHost: 'fd-dev',
          foreground: false,
        ),
        isTrue,
      );
    });
    test('no activeHost but activeSessionId same host → suppress (fallback)', () {
      expect(
        shouldPostAttention(
          signalSessionId: sessA,
          activeSessionId: sessB, // same host fd-dev
          foreground: true,
        ),
        isFalse,
      );
    });
    test('no active host info at all → fire', () {
      expect(
        shouldPostAttention(
          signalSessionId: sessA,
          activeSessionId: null,
          foreground: true,
        ),
        isTrue,
      );
    });
  });

  group('AttentionDedupTracker host-level window (#847)', () {
    test('2 sessions to SAME host within window → 1 allowed', () {
      var now = 1000;
      final dedup = AttentionDedupTracker(
        window: const Duration(seconds: 30),
        nowMs: () => now,
      );
      // First bell (session A on fd-dev) fires.
      expect(dedup.allow('fd-dev'), isTrue);
      // 5s later, session B on the SAME host bells → deduped.
      now += 5000;
      expect(dedup.allow('fd-dev'), isFalse);
    });

    test('2 DIFFERENT hosts → both allowed', () {
      var now = 1000;
      final dedup = AttentionDedupTracker(
        window: const Duration(seconds: 30),
        nowMs: () => now,
      );
      expect(dedup.allow('host-a'), isTrue);
      expect(dedup.allow('host-b'), isTrue);
    });

    test('same host OUTSIDE the window → allowed again', () {
      var now = 1000;
      final dedup = AttentionDedupTracker(
        window: const Duration(seconds: 30),
        nowMs: () => now,
      );
      expect(dedup.allow('fd-dev'), isTrue);
      now += 31000; // past the 30s window
      expect(dedup.allow('fd-dev'), isTrue);
    });

    test('window measures from last FIRED post, not last attempt', () {
      var now = 1000;
      final dedup = AttentionDedupTracker(
        window: const Duration(seconds: 30),
        nowMs: () => now,
      );
      expect(dedup.allow('h'), isTrue); // fires at t=1000
      now += 20000; // t=21000, within window → deduped, stamp NOT moved
      expect(dedup.allow('h'), isFalse);
      now += 11000; // t=32000, 31s after the FIRED post → allowed again
      expect(dedup.allow('h'), isTrue);
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
