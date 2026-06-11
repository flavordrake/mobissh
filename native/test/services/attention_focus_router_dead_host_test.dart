// Dead-host tap routing (#885): an attention notification must not outlive its
// ability to deliver. When the tapped payload's HOST has NO live session
// (route='none' — cold start after process death, or the session closed), the
// router must either:
//
//   * RECONNECT: when the injected `reconnectHost` seam is wired and resolves a
//     new sessionId (a profile exists for the host and the reconnect flow
//     produced a session entry), focus that new session and log
//     `route=reconnect host=…`; or
//   * CANCEL: when the seam is unwired, resolves null (no profile / no creds),
//     or throws — cancel the host's notification via the injected
//     `cancelHostNotification` seam (so the dead notification doesn't dangle)
//     and log `route=cancelled host=…`.
//
// Never the pre-#885 behavior: silently return null and strand the user on the
// connect view with the notification still posted.
//
// All platform effects are injected — these tests run without Flutter bindings.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/attention_focus_router.dart';
import 'package:mobissh/services/session_attention_notification.dart';

void main() {
  group('AttentionFocusRouter dead-host tap (#885)', () {
    const staleSid = 'fddev:22:me:100'; // payload id; host fddev has no session
    const newSid = 'fddev:22:me:999'; // the session the reconnect flow creates

    Future<PendingFocusBridge> seededBridge() async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': staleSid}));
      return bridge;
    }

    test(
      'reconnect seam wired + profile exists → reconnect invoked, new session '
      'focused, route=reconnect logged, NO cancel',
      () async {
        final bridge = await seededBridge();
        final activated = <String>[];
        final reconnected = <String>[];
        final cancelled = <String>[];
        final logs = <String>[];
        final router = AttentionFocusRouter(
          bridge: bridge,
          setActive: activated.add,
          sessionExists: (_) => false,
          sendInput: (a, b) {},
          resolveLiveSessionForHost: (_) => null,
          reconnectHost: (host) async {
            reconnected.add(host);
            return newSid; // profile resolved + reconnect flow created a session
          },
          cancelHostNotification: (host) async => cancelled.add(host),
          log: (where, msg) => logs.add(msg),
        );

        final focused = await router.consumePending();

        expect(reconnected, ['fddev'],
            reason: 'the dead-host tap must trigger the host profile reconnect');
        expect(focused, newSid);
        expect(activated, [newSid],
            reason: 'the tap must focus the reconnected session once it exists');
        expect(cancelled, isEmpty,
            reason: 'a successful reconnect keeps delivering — nothing to cancel');
        expect(logs.any((l) => l.contains('route=reconnect host=fddev')), isTrue,
            reason: 'route decision must be capturable: $logs');
      },
    );

    test(
      'reconnect seam wired but NO profile (resolves null) → cancel invoked, '
      'route=cancelled logged, nothing focused',
      () async {
        final bridge = await seededBridge();
        final activated = <String>[];
        final cancelled = <String>[];
        final logs = <String>[];
        final router = AttentionFocusRouter(
          bridge: bridge,
          setActive: activated.add,
          sessionExists: (_) => false,
          sendInput: (a, b) {},
          reconnectHost: (_) async => null, // no profile / no usable creds
          cancelHostNotification: (host) async => cancelled.add(host),
          log: (where, msg) => logs.add(msg),
        );

        final focused = await router.consumePending();

        expect(focused, isNull);
        expect(activated, isEmpty);
        expect(cancelled, ['fddev'],
            reason: 'an undeliverable notification must be cancelled, not left '
                'dangling');
        expect(logs.any((l) => l.contains('route=cancelled host=fddev')), isTrue,
            reason: 'route decision must be capturable: $logs');
      },
    );

    test('reconnect seam ABSENT → cancel invoked (route=cancelled)', () async {
      final bridge = await seededBridge();
      final cancelled = <String>[];
      final logs = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => false,
        sendInput: (a, b) {},
        cancelHostNotification: (host) async => cancelled.add(host),
        log: (where, msg) => logs.add(msg),
      );

      expect(await router.consumePending(), isNull);
      expect(cancelled, ['fddev']);
      expect(logs.any((l) => l.contains('route=cancelled host=fddev')), isTrue);
    });

    test('reconnect seam THROWS → falls back to cancel, tap never crashes',
        () async {
      final bridge = await seededBridge();
      final cancelled = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => false,
        sendInput: (a, b) {},
        reconnectHost: (_) async => throw StateError('reconnect boom'),
        cancelHostNotification: (host) async => cancelled.add(host),
      );

      // Must not throw.
      expect(await router.consumePending(), isNull);
      expect(cancelled, ['fddev']);
    });

    test('cancel seam ABSENT too → still returns null without crashing',
        () async {
      final bridge = await seededBridge();
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => false,
        sendInput: (a, b) {},
      );
      expect(await router.consumePending(), isNull);
    });

    test('cancel seam THROWS → swallowed, tap never crashes', () async {
      final bridge = await seededBridge();
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => false,
        sendInput: (a, b) {},
        cancelHostNotification: (_) async => throw StateError('cancel boom'),
      );
      expect(await router.consumePending(), isNull);
    });

    test(
      'LIVE session for the payload id → existing routing unchanged: '
      'setActive(payload sid), reconnect + cancel never invoked',
      () async {
        final bridge = await seededBridge();
        final activated = <String>[];
        final reconnected = <String>[];
        final cancelled = <String>[];
        final router = AttentionFocusRouter(
          bridge: bridge,
          setActive: activated.add,
          sessionExists: (id) => id == staleSid, // payload id IS live
          sendInput: (a, b) {},
          reconnectHost: (host) async {
            reconnected.add(host);
            return newSid;
          },
          cancelHostNotification: (host) async => cancelled.add(host),
        );

        final focused = await router.consumePending();
        expect(focused, staleSid);
        expect(activated, [staleSid]);
        expect(reconnected, isEmpty,
            reason: 'a live session routes via setActive — never reconnects');
        expect(cancelled, isEmpty);
      },
    );

    test(
      'HOST-FALLBACK (#857) still wins over reconnect: stale payload id but the '
      'host has a live session → setActive(live), no reconnect, no cancel',
      () async {
        final bridge = await seededBridge();
        const liveSid = 'fddev:22:me:500';
        final activated = <String>[];
        final reconnected = <String>[];
        final cancelled = <String>[];
        final router = AttentionFocusRouter(
          bridge: bridge,
          setActive: activated.add,
          sessionExists: (id) => id == liveSid,
          sendInput: (a, b) {},
          resolveLiveSessionForHost: (host) => host == 'fddev' ? liveSid : null,
          reconnectHost: (host) async {
            reconnected.add(host);
            return newSid;
          },
          cancelHostNotification: (host) async => cancelled.add(host),
        );

        final focused = await router.consumePending();
        expect(focused, liveSid);
        expect(activated, [liveSid]);
        expect(reconnected, isEmpty);
        expect(cancelled, isEmpty);
      },
    );

    test(
      'cold-start seed (#878) composes: a seeded payload for a dead host drives '
      'the same reconnect path on the boot consume',
      () async {
        // Mirrors AttentionUiTapBinding.seedColdStart: the launch-details payload
        // is written as pending, then the boot path's consumePending routes it.
        final bridge = PendingFocusBridge(MapKeyValueStore());
        await bridge.setPendingFromPayload(jsonEncode({'sessionId': staleSid}));

        final activated = <String>[];
        final reconnected = <String>[];
        final router = AttentionFocusRouter(
          bridge: bridge,
          setActive: activated.add,
          sessionExists: (_) => false,
          sendInput: (a, b) {},
          reconnectHost: (host) async {
            reconnected.add(host);
            return newSid;
          },
          cancelHostNotification: (_) async {},
        );

        final focused = await router.consumePending(); // the boot consume
        expect(reconnected, ['fddev']);
        expect(focused, newSid);
        expect(activated, [newSid]);
      },
    );

    test('nothing pending → reconnect/cancel never invoked', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final reconnected = <String>[];
      final cancelled = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => false,
        sendInput: (a, b) {},
        reconnectHost: (host) async {
          reconnected.add(host);
          return null;
        },
        cancelHostNotification: (host) async => cancelled.add(host),
      );
      expect(await router.consumePending(), isNull);
      expect(reconnected, isEmpty);
      expect(cancelled, isEmpty);
    });
  });
}
