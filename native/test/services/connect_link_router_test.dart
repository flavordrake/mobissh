// #1141 (PR C of #1117) — ConnectLinkRouter unit tests. Pure Dart, no Flutter.
//
// A4: first connect confirms (R12); "Always allow" persists linkAutoConnect
//     (R13); the next link skips the prompt; revoking restores it.
// A5: `create` / unmatched host opens the editor pre-filled and never
//     connects or focuses (R11, R14).
// A6: a rejected link touches nothing but the log (R26, R27).
// R17: the matched profile is the ONLY profile handed to the connect seam; a
//      live session is focused only when its profileKey equals the matched
//      identity; the session count never grows on focus.
// R18: the pending record round-trips through "process death" (a fresh
//      router over the same store consumes it exactly once).
// R22 (deferred to PR E): `tmux` rides the pending record untouched and the
//      router has no PTY seam to send it through.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/services/connect_link_router.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/storage/profiles_store.dart';

class _Spy {
  final List<String> log = [];
  final List<SavedProfile> confirmed = [];
  final List<SavedProfile> persisted = [];
  final List<SavedProfile> connected = [];
  final List<SavedProfile> created = [];
  final List<List<SavedProfile>> picked = [];
  final List<String> activated = [];
  int rejections = 0;
  LinkConfirmChoice? confirmAnswer = LinkConfirmChoice.once;
  SavedProfile? pickAnswer;
  List<LiveSessionRef> live = const [];
  List<SavedProfile> profiles = const [];

  ConnectLinkRouter build(PendingLinkBridge bridge) => ConnectLinkRouter(
        bridge: bridge,
        loadProfiles: () async => profiles,
        liveSessions: () => live,
        setActive: activated.add,
        confirm: (p) async {
          confirmed.add(p);
          return confirmAnswer;
        },
        pick: (c) async {
          picked.add(c);
          return pickAnswer;
        },
        persistAutoConnect: (p) async {
          persisted.add(p);
          profiles = [
            for (final q in profiles)
              q.identityKey == p.identityKey ? p : q,
          ];
        },
        connectProfile: (p) async => connected.add(p),
        openCreate: (p) async => created.add(p),
        reject: () => rejections++,
        log: (where, msg) => log.add('$where: $msg'),
      );
}

final _alice = SavedProfile(
  title: 'Alice box',
  host: 'box.example',
  port: 22,
  username: 'alice',
  linkAlias: 'alice',
);
final _bob = SavedProfile(
  title: 'Bob box',
  host: 'box.example',
  port: 22,
  username: 'bob',
);

void main() {
  late MapKeyValueStore store;
  late _Spy spy;
  late ConnectLinkRouter router;

  setUp(() {
    store = MapKeyValueStore();
    spy = _Spy()..profiles = [_alice, _bob];
    router = spy.build(PendingLinkBridge(store));
  });

  group('A4 confirmation + linkAutoConnect', () {
    test('first connect confirms; Connect once does not persist', () async {
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.confirmed.map((p) => p.identityKey), [_alice.identityKey]);
      expect(spy.persisted, isEmpty);
      expect(spy.connected.map((p) => p.identityKey), [_alice.identityKey]);
    });

    test('Always allow persists linkAutoConnect and the next link skips the '
        'prompt; setting it back restores the prompt', () async {
      spy.confirmAnswer = LinkConfirmChoice.always;
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.persisted.single.linkAutoConnect, isTrue);
      expect(spy.persisted.single.identityKey, _alice.identityKey);

      spy.confirmAnswer = null; // would cancel if asked
      await router.deliver('mobissh://connect?name=alice');
      expect(spy.confirmed.length, 1, reason: 'no second prompt');
      expect(spy.connected.length, 2);

      spy.profiles = [_alice.copyWith(linkAutoConnect: false), _bob];
      await router.deliver('mobissh://connect?name=alice');
      expect(spy.confirmed.length, 2, reason: 'revoked → prompt again');
      expect(spy.connected.length, 2, reason: 'cancelled prompt → no connect');
      expect(spy.persisted.length, 1);
    });

    test('a picker result always confirms (R14)', () async {
      spy.pickAnswer = _bob;
      await router.deliver('mobissh://connect?host=box.example');
      expect(spy.picked.single.map((p) => p.username), ['alice', 'bob']);
      expect(spy.confirmed.single.identityKey, _bob.identityKey);
      expect(spy.connected.single.identityKey, _bob.identityKey);
    });
  });

  group('A5 create / unmatched host', () {
    test('create opens the editor pre-filled and never connects', () async {
      await router.deliver(
        'mobissh://create?host=new.example&port=2200&user=carol&name=Newbox',
      );
      final draft = spy.created.single;
      expect(draft.host, 'new.example');
      expect(draft.port, 2200);
      expect(draft.username, 'carol');
      expect(draft.title, 'Newbox');
      expect(draft.linkAutoConnect, isFalse);
      expect(draft.vaultId, isNull);
      expect(draft.keyVaultId, isNull);
      expect(spy.connected, isEmpty);
      expect(spy.activated, isEmpty);
      expect(spy.persisted, isEmpty);
      expect(spy.confirmed, isEmpty);
    });

    test('connect to an unsaved host opens the editor (R9 zero)', () async {
      await router.deliver('mobissh://connect?host=unknown.example&user=x');
      expect(spy.created.single.host, 'unknown.example');
      expect(spy.created.single.username, 'x');
      expect(spy.connected, isEmpty);
      expect(spy.rejections, 0);
    });

    test('create for an existing identity shows its confirmation (R11)',
        () async {
      await router.deliver('mobissh://create?host=box.example&user=alice');
      expect(spy.created, isEmpty);
      expect(spy.confirmed.single.identityKey, _alice.identityKey);
    });
  });

  group('A6 rejection touches nothing (R26/R27)', () {
    for (final link in [
      'ssh://box.example',
      'mobissh://open?host=box.example',
      'mobissh://connect?name=nobody',
      'mobissh://connect?host=box.example&claude=00000000-0000-0000-0000-000000000000',
      'not a link at all',
    ]) {
      test('rejects $link with only a redacted log line', () async {
        await router.deliver(link);
        expect(spy.rejections, 1);
        expect(spy.confirmed, isEmpty);
        expect(spy.persisted, isEmpty);
        expect(spy.connected, isEmpty);
        expect(spy.created, isEmpty);
        expect(spy.picked, isEmpty);
        expect(spy.activated, isEmpty);
        expect(await store.getString('mobissh.link.pending'), isNull);
        final lines = spy.log.where((l) => l.contains('rejected')).toList();
        expect(lines, hasLength(1));
        expect(lines.single, isNot(contains('box.example')));
        expect(lines.single, isNot(contains('nobody')));
        expect(lines.single, isNot(contains(link)));
      });
    }

    test('a duplicated alias is rejected, never the first hit (R10)',
        () async {
      spy.profiles = [_alice, _bob.copyWith(linkAlias: 'alice')];
      await router.deliver('mobissh://connect?name=alice');
      expect(spy.rejections, 1);
      expect(spy.picked, isEmpty);
      expect(spy.connected, isEmpty);
    });
  });

  group('R17 idempotent focus', () {
    test('a live session for the matched identity is focused, not reconnected',
        () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
      spy.live = [
        LiveSessionRef(id: 'bob-sid', profileKey: _bob.identityKey),
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.activated, ['alice-sid']);
      expect(spy.connected, isEmpty);
      expect(spy.confirmed, isEmpty);
    });

    test('only the matched profile reaches the connect seam', () async {
      spy.profiles = [_bob, _alice.copyWith(linkAutoConnect: true)];
      spy.live = [
        LiveSessionRef(id: 'bob-sid', profileKey: _bob.identityKey),
      ];
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.activated, isEmpty, reason: 'bob is a different identity');
      expect(spy.connected.single.identityKey, _alice.identityKey);
      expect(spy.connected.single.username, 'alice');
    });
  });

  group('R18 pending record', () {
    test('round-trips through process death and is consumed once', () async {
      final bridge = PendingLinkBridge(store);
      await bridge.setPending(const ConnectRequest(
        verb: ConnectVerb.connect,
        host: 'box.example',
        user: 'alice',
        tmux: 'work',
      ));
      final raw = await store.getString('mobissh.link.pending');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('mobissh://')));

      spy.profiles = [_alice.copyWith(linkAutoConnect: true)];
      final fresh = spy.build(PendingLinkBridge(store));
      await fresh.consumePending();
      expect(spy.connected.single.identityKey, _alice.identityKey);
      expect(await store.getString('mobissh.link.pending'), isNull);

      await fresh.consumePending();
      expect(spy.connected.length, 1, reason: 'consumed exactly once');
    });

    test('tmux is carried through untouched and never sent anywhere',
        () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true)];
      final bridge = PendingLinkBridge(store);
      await bridge.setPending(const ConnectRequest(
        verb: ConnectVerb.connect,
        host: 'box.example',
        user: 'alice',
        tmux: 'work',
      ));
      final pending = await bridge.readPending();
      expect(pending?.tmux, 'work');
      await router.consumePending();
      expect(spy.connected.single.identityKey, _alice.identityKey);
      expect(spy.log.join('\n'), isNot(contains('work')));
    });
  });
}
