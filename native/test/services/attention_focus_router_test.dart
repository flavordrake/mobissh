// Unit tests for the attention focus router + tmux select-window builder
// (#840, Slice 2).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/attention_focus_router.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/services/tmux_window_select.dart';

void main() {
  group('AttentionFocusRouter.consumePending', () {
    test('routes to the pending session via setActive', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': 'A'}));

      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
      );

      final focused = await router.consumePending();
      expect(focused, 'A');
      expect(activated, ['A']);
    });

    test('one-shot: a second consume does nothing', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': 'A'}));
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
      );
      await router.consumePending();
      await router.consumePending();
      expect(activated, ['A']); // only once
    });

    test('stale session id (no longer exists) → no setActive', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': 'gone'}));
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => false,
        sendInput: (a, b) {},
      );
      final focused = await router.consumePending();
      expect(focused, isNull);
      expect(activated, isEmpty);
    });

    test('nothing pending → null, no calls', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
      );
      expect(await router.consumePending(), isNull);
      expect(activated, isEmpty);
    });

    test('GUARDED (win N): sends select-window only when tmux', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(
        jsonEncode({'sessionId': 'A', 'sourceWindow': 4}),
      );
      final sent = <(String, List<int>)>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => true,
        sendInput: (id, bytes) => sent.add((id, bytes)),
        isTmux: (_) => true,
      );
      await router.consumePending();
      expect(sent, hasLength(1));
      expect(sent.single.$1, 'A');
      expect(sent.single.$2, tmuxSelectWindowSequence(4));
    });

    test('GUARDED: NON-tmux session → no select-window sent', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(
        jsonEncode({'sessionId': 'A', 'sourceWindow': 4}),
      );
      final sent = <(String, List<int>)>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => true,
        sendInput: (id, bytes) => sent.add((id, bytes)),
        isTmux: (_) => false,
      );
      await router.consumePending();
      expect(sent, isEmpty);
    });

    test('GUARDED: no (win N) hint → no select-window even if tmux', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': 'A'}));
      final sent = <(String, List<int>)>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => true,
        sendInput: (id, bytes) => sent.add((id, bytes)),
        isTmux: (_) => true,
      );
      await router.consumePending();
      expect(sent, isEmpty);
    });

    test('URL payload (#710): focuses the session AND opens the URL', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({
        'sessionId': 'A',
        'url': 'https://example.com/app.apk',
      }));
      final activated = <String>[];
      final opened = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
        openUrl: (u) async => opened.add(u),
      );
      final focused = await router.consumePending();
      expect(focused, 'A');
      expect(activated, ['A'], reason: 'tap still focuses the session');
      expect(opened, ['https://example.com/app.apk']);
    });

    test('no url payload (#710): focuses, does NOT call openUrl', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': 'A'}));
      final activated = <String>[];
      final opened = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
        openUrl: (u) async => opened.add(u),
      );
      await router.consumePending();
      expect(activated, ['A']);
      expect(opened, isEmpty);
    });

    test('malformed / non-http url (#710): not launched', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({
        'sessionId': 'A',
        'url': 'javascript:alert(1)',
      }));
      final opened = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (_) => true,
        sendInput: (a, b) {},
        openUrl: (u) async => opened.add(u),
      );
      await router.consumePending();
      expect(opened, isEmpty, reason: 'only well-formed http(s) URLs launch');
    });

    test('openUrl that throws does not crash the tap (#710)', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({
        'sessionId': 'A',
        'url': 'https://example.com/x',
      }));
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
        openUrl: (_) async => throw StateError('launch boom'),
      );
      // Must not throw — launch errors are swallowed; focus still happens.
      final focused = await router.consumePending();
      expect(focused, 'A');
      expect(activated, ['A']);
    });

    test('stale session with url payload → neither setActive nor openUrl (#710)',
        () async {
      // NOTE: with the #857 host-fallback this only holds when the host has NO
      // live session. `resolveLiveSessionForHost` defaults to returning null, so
      // a router with no host-resolver still gives up on a stale id.
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({
        'sessionId': 'gone',
        'url': 'https://example.com/x',
      }));
      final activated = <String>[];
      final opened = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => false,
        sendInput: (a, b) {},
        openUrl: (u) async => opened.add(u),
      );
      expect(await router.consumePending(), isNull);
      expect(activated, isEmpty);
      expect(opened, isEmpty);
    });
  });

  // #857: tapping an attention notification must route to the notification's OWN
  // session, NOT the previously-active one. The bug: when the payload's exact
  // sessionId is no longer live (the host reconnected with a new `createdAtMs`
  // nonce), the router no-op'd → UI stayed on the current (wrong) session.
  group('AttentionFocusRouter host fallback (#857)', () {
    test('exact-id live: routes to host-B session, not current A', () async {
      const bId = 'fddev:22:me:200';
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': bId}));
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (id) => id == bId, // current active is raserver (A)
        sendInput: (a, b) {},
        resolveLiveSessionForHost: (_) => null,
      );
      final focused = await router.consumePending();
      expect(focused, bId);
      expect(activated, [bId], reason: 'routes to B, never the current A');
    });

    test('exact id NOT live but host B has a live session (diff nonce) → '
        'setActive that B session, not A', () async {
      // Payload carries the OLD fddev id; fddev reconnected with a new nonce.
      const staleB = 'fddev:22:me:100';
      const liveB = 'fddev:22:me:999';
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': staleB}));
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (id) => id == liveB, // staleB is gone; liveB is current B
        sendInput: (a, b) {},
        resolveLiveSessionForHost: (host) => host == 'fddev' ? liveB : null,
      );
      final focused = await router.consumePending();
      expect(focused, liveB, reason: 'falls back to the live host-B session');
      expect(activated, [liveB],
          reason: 'must NOT stay on the current (raserver) session');
    });

    test('host has NO live session → no switch (stay)', () async {
      const staleB = 'fddev:22:me:100';
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({'sessionId': staleB}));
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => false,
        sendInput: (a, b) {},
        resolveLiveSessionForHost: (_) => null,
      );
      final focused = await router.consumePending();
      expect(focused, isNull);
      expect(activated, isEmpty);
    });

    test('host fallback + url: BOTH setActive the live B session AND openUrl',
        () async {
      const staleB = 'fddev:22:me:100';
      const liveB = 'fddev:22:me:999';
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(jsonEncode({
        'sessionId': staleB,
        'url': 'https://example.com/app.apk',
      }));
      final activated = <String>[];
      final opened = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (id) => id == liveB,
        sendInput: (a, b) {},
        resolveLiveSessionForHost: (host) => host == 'fddev' ? liveB : null,
        openUrl: (u) async => opened.add(u),
      );
      final focused = await router.consumePending();
      expect(focused, liveB);
      expect(activated, [liveB]);
      expect(opened, ['https://example.com/app.apk'],
          reason: 'the #710 url-open must still fire on the host-fallback path');
    });

    test('host fallback sends select-window to the RESOLVED live B session',
        () async {
      const staleB = 'fddev:22:me:100';
      const liveB = 'fddev:22:me:999';
      final bridge = PendingFocusBridge(MapKeyValueStore());
      await bridge.setPendingFromPayload(
        jsonEncode({'sessionId': staleB, 'sourceWindow': 4}),
      );
      final sent = <(String, List<int>)>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: (_) {},
        sessionExists: (id) => id == liveB,
        sendInput: (id, bytes) => sent.add((id, bytes)),
        isTmux: (_) => true,
        resolveLiveSessionForHost: (host) => host == 'fddev' ? liveB : null,
      );
      await router.consumePending();
      expect(sent, hasLength(1));
      expect(sent.single.$1, liveB,
          reason: 'window-select goes to the live session, not the stale id');
    });
  });

  group('tmuxSelectWindowSequence', () {
    test('builds prefix + :select-window -t N + Enter', () {
      final seq = tmuxSelectWindowSequence(7);
      expect(seq.first, 0x02); // Ctrl-B prefix
      final tail = String.fromCharCodes(seq.sublist(1));
      expect(tail, ':select-window -t 7\r');
    });

    test('works for >= 10', () {
      final seq = tmuxSelectWindowSequence(12);
      expect(String.fromCharCodes(seq.sublist(1)), ':select-window -t 12\r');
    });

    test('negative index throws', () {
      expect(() => tmuxSelectWindowSequence(-1), throwsArgumentError);
    });
  });
}
