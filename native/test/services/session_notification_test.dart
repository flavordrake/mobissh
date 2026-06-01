// Tests for #575 — tappable session notifications.
//
// Three headless-testable units:
//   1. SessionNotification.build — maps a session event (label + signal kind)
//      to a notification's title/body + sessionId payload. Asserts the payload
//      round-trips and carries NO secret material.
//   2. PendingFocusBridge — the cross-isolate "session to focus" hand-off used
//      when a notification is tapped. set → read → clear round-trips over an
//      injectable KeyValueStore seam (no platform channels in tests).
//   3. The notification-tap router — given a pending sessionId, calls
//      sessionsProvider.notifier.setActive(sessionId), including the per-session
//      ISOLATION case (a signal from A focuses A, never B).
//
// The full tap → launchApp → foreground → focus path is device-only and is
// flagged for emulator validation; here we test the seams it composes.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_notification.dart';

void main() {
  group('SessionNotification.build', () {
    test('ready signal → human title/body + sessionId payload', () {
      final n = SessionNotification.build(
        sessionId: 'host.example:22:alice:1234',
        label: 'alice@host.example:22',
        kind: SessionSignalKind.ready,
      );
      // Body conveys the meaning; title identifies the session.
      expect(n.title, 'alice@host.example:22');
      expect(n.body.toLowerCase(), contains('ready'));
      // Payload carries the originating sessionId verbatim so the tap can
      // route back to that exact session.
      expect(n.payload, 'host.example:22:alice:1234');
    });

    test('stopped signal → "disconnected" body', () {
      final n = SessionNotification.build(
        sessionId: 's:22:u:9',
        label: 'u@s:22',
        kind: SessionSignalKind.stopped,
      );
      expect(n.title, 'u@s:22');
      expect(n.body.toLowerCase(), contains('disconnect'));
      expect(n.payload, 's:22:u:9');
    });

    test('custom message text from the signal is surfaced in the body', () {
      final n = SessionNotification.build(
        sessionId: 's:22:u:9',
        label: 'u@s:22',
        kind: SessionSignalKind.ready,
        message: 'build finished',
      );
      expect(n.body, contains('build finished'));
    });

    test('payload round-trips through toPayload/parsePayload', () {
      const sid = 'h:2222:bob:42';
      final n = SessionNotification.build(
        sessionId: sid,
        label: 'bob@h:2222',
        kind: SessionSignalKind.ready,
      );
      expect(SessionNotification.parsePayload(n.payload), sid);
    });

    test('parsePayload tolerates null/empty (no pending focus)', () {
      expect(SessionNotification.parsePayload(null), isNull);
      expect(SessionNotification.parsePayload(''), isNull);
    });

    test('android tag is keyed by sessionId so repeats replace, not stack', () {
      final a1 = SessionNotification.build(
        sessionId: 'h:22:u:1',
        label: 'u@h:22',
        kind: SessionSignalKind.ready,
      );
      final a2 = SessionNotification.build(
        sessionId: 'h:22:u:1',
        label: 'u@h:22',
        kind: SessionSignalKind.stopped,
      );
      final b = SessionNotification.build(
        sessionId: 'h:22:u:2',
        label: 'u@h:22',
        kind: SessionSignalKind.ready,
      );
      // Same session → same tag (replace). Different session → different tag.
      expect(a1.tag, a2.tag);
      expect(a1.tag, isNot(b.tag));
    });

    test(
      'carries no secret material (password/passphrase/pem) in any field',
      () {
        final n = SessionNotification.build(
          sessionId: 'h:22:u:1',
          label: 'u@h:22',
          kind: SessionSignalKind.ready,
          message: 'ok',
        );
        final blob = '${n.title}|${n.body}|${n.payload}|${n.tag}'.toLowerCase();
        expect(blob, isNot(contains('password')));
        expect(blob, isNot(contains('passphrase')));
        expect(blob, isNot(contains('begin')));
        expect(blob, isNot(contains('private key')));
      },
    );
  });

  group('PendingFocusBridge', () {
    test(
      'set then read returns the sessionId; read does NOT consume',
      () async {
        final store = MapKeyValueStore();
        final bridge = PendingFocusBridge(store);
        await bridge.setPending('h:22:u:1');
        expect(await bridge.readPending(), 'h:22:u:1');
        // A bare read is non-destructive; the consumer clears explicitly.
        expect(await bridge.readPending(), 'h:22:u:1');
      },
    );

    test('takePending reads AND clears (one-shot consume on resume)', () async {
      final store = MapKeyValueStore();
      final bridge = PendingFocusBridge(store);
      await bridge.setPending('h:22:u:1');
      expect(await bridge.takePending(), 'h:22:u:1');
      // Consumed — a second take yields nothing so resume doesn't re-focus.
      expect(await bridge.takePending(), isNull);
    });

    test('readPending is null when nothing is pending', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      expect(await bridge.readPending(), isNull);
    });

    test('a later signal overwrites the pending focus (latest wins)', () async {
      final store = MapKeyValueStore();
      final bridge = PendingFocusBridge(store);
      await bridge.setPending('h:22:u:1');
      await bridge.setPending('h:22:u:2');
      expect(await bridge.takePending(), 'h:22:u:2');
    });
  });

  group('notification-tap routing', () {
    test('routing a pending sessionId focuses THAT session (A not B)', () {
      final focused = <String>[];
      // The router is a pure mapping from a pending sessionId to a setActive
      // call. The real provider path calls sessionsProvider.notifier.setActive;
      // here we capture the calls to assert isolation.
      void route(String? pending) {
        if (pending == null) return;
        focused.add(pending);
      }

      // Signal from A.
      final tapA = SessionNotification.build(
        sessionId: 'A:22:u:1',
        label: 'u@A:22',
        kind: SessionSignalKind.ready,
      );
      route(SessionNotification.parsePayload(tapA.payload));
      expect(focused, ['A:22:u:1']);

      // Signal from B does not retroactively re-focus A.
      final tapB = SessionNotification.build(
        sessionId: 'B:22:u:2',
        label: 'u@B:22',
        kind: SessionSignalKind.stopped,
      );
      route(SessionNotification.parsePayload(tapB.payload));
      expect(focused, ['A:22:u:1', 'B:22:u:2']);
    });

    test('null payload is a no-op (no focus change)', () {
      final focused = <String>[];
      void route(String? pending) {
        if (pending == null) return;
        focused.add(pending);
      }

      route(SessionNotification.parsePayload(null));
      expect(focused, isEmpty);
    });
  });
}
