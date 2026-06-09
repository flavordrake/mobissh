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
