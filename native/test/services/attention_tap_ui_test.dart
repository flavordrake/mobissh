// Unit tests for the UI-isolate notification-tap binding (#878).
//
// #878 root cause: `flutter_local_notifications` delivers a plain tap to the
// isolate that initialized the plugin IN THE LAUNCHED ENGINE — the UI isolate
// never initialized it, so the tap (and its payload) was silently dropped and
// the pending-focus write never happened (the root of the #857/#870 wrong-host
// saga). The fix registers an FLN init in the UI isolate whose tap handler is
// this pure seam: write pending via the bridge, then IMMEDIATELY consume (the
// tap IS the resume). Cold start seeds pending from the launch details BEFORE
// the initial consume.
//
// These tests exercise the seam with the real PendingFocusBridge +
// AttentionFocusRouter over in-memory fakes — no platform channels.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/attention_focus_router.dart';
import 'package:mobissh/services/attention_tap_ui.dart';
import 'package:mobissh/services/session_attention_notification.dart';

void main() {
  group('AttentionUiTapBinding.handleTap (warm tap)', () {
    test('writes pending AND immediately consumes → setActive', () async {
      final store = MapKeyValueStore();
      final bridge = PendingFocusBridge(store);
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
      );
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: router.consumePending,
      );

      await binding.handleTap(jsonEncode({'sessionId': 'h:22:u:111'}));

      // The tap routed without waiting for any later resume/lifecycle event.
      expect(activated, ['h:22:u:111']);
      // Consumed one-shot: nothing left pending for the next resume.
      expect((await bridge.readPending()).sessionId, isNull);
    });

    test('stale sid nonce → host-fallback still applies', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (id) => id == 'h:22:u:222', // reconnected nonce
        sendInput: (a, b) {},
        resolveLiveSessionForHost: (host) =>
            host == 'h' ? 'h:22:u:222' : null,
      );
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: router.consumePending,
      );

      await binding.handleTap(jsonEncode({'sessionId': 'h:22:u:111'}));

      expect(activated, ['h:22:u:222']);
    });

    test('null payload: no pending write, consume still fires', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      var consumed = 0;
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: () async {
          consumed++;
          return null;
        },
      );

      await binding.handleTap(null);

      expect(consumed, 1);
      expect((await bridge.readPending()).sessionId, isNull);
    });

    test('consume failure is swallowed; pending was still written', () async {
      final store = MapKeyValueStore();
      final bridge = PendingFocusBridge(store);
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: () async => throw StateError('router exploded'),
      );

      // Must not throw — a tap handler crash would break the notification path.
      await binding.handleTap(jsonEncode({'sessionId': 'h:22:u:111'}));

      // The write happened before the consume attempt, so a later resume's
      // ordinary consumePending can still route it.
      expect((await bridge.readPending()).sessionId, 'h:22:u:111');
    });

    test('telemetry: tap received + immediate-consume outcome logged',
        () async {
      final lines = <String>[];
      final bridge = PendingFocusBridge(
        MapKeyValueStore(),
        log: (where, msg) => lines.add('[$where] $msg'),
      );
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
      );
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: router.consumePending,
        log: (where, msg) => lines.add('[$where] $msg'),
      );

      await binding.handleTap(jsonEncode({'sessionId': 'h:22:u:111'}));

      // Tap received (sid/host only — never auth material).
      expect(lines.any((l) => l.contains('tap') && l.contains('h:22:u:111')),
          isTrue);
      // Pending written (bridge's own write log).
      expect(lines.any((l) => l.contains('pending set')), isTrue);
      // Immediate-consume outcome.
      expect(
        lines.any((l) => l.contains('consume') && l.contains('h:22:u:111')),
        isTrue,
      );
    });
  });

  group('AttentionUiTapBinding.seedColdStart (launch details)', () {
    test('seeds pending so the initial consume routes to that host', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (_) => true,
        sendInput: (a, b) {},
      );
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: router.consumePending,
      );

      // Cold start: seed BEFORE the app's initial consume runs.
      await binding.seedColdStart(jsonEncode({'sessionId': 'h:22:u:111'}));
      expect(activated, isEmpty); // seeding does NOT consume

      // …then the boot-path initial consume routes it.
      await router.consumePending();
      expect(activated, ['h:22:u:111']);
    });

    test('stale sid nonce at cold start → host-fallback still applies',
        () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final activated = <String>[];
      final router = AttentionFocusRouter(
        bridge: bridge,
        setActive: activated.add,
        sessionExists: (id) => id == 'h:22:u:999',
        sendInput: (a, b) {},
        resolveLiveSessionForHost: (host) =>
            host == 'h' ? 'h:22:u:999' : null,
      );
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: router.consumePending,
      );

      await binding.seedColdStart(jsonEncode({'sessionId': 'h:22:u:111'}));
      await router.consumePending();

      expect(activated, ['h:22:u:999']);
    });

    test('null / payload-less launch details → no-op', () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final binding = AttentionUiTapBinding(
        bridge: bridge,
        consume: () async => null,
      );

      await binding.seedColdStart(null);

      expect((await bridge.readPending()).sessionId, isNull);
    });
  });
}
