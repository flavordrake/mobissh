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
// R22/R23b/R25 (PR E, #1149): the verb is a typed command built from the
//      validated token; a fresh connect carries it through the connect seam,
//      a live same-identity session ALWAYS asks (`confirmSend`) before the
//      router hands it to the send seam — regardless of linkAutoConnect.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/services/connect_link_router.dart';
import 'package:mobissh/services/link_verb.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/storage/profiles_store.dart';

class _Spy {
  final List<String> log = [];
  final List<SavedProfile> confirmed = [];
  final List<LinkVerbCommand?> confirmedVerbs = [];
  final List<SavedProfile> persisted = [];
  final List<SavedProfile> connected = [];
  final List<LinkVerbCommand?> connectedVerbs = [];
  final List<SavedProfile> created = [];
  final List<List<SavedProfile>> picked = [];
  final List<String> activated = [];
  final List<String> confirmSends = [];
  final List<String> sent = [];
  int rejections = 0;
  LinkConfirmChoice? confirmAnswer = LinkConfirmChoice.once;
  bool confirmSendAnswer = true;
  SavedProfile? pickAnswer;
  List<LiveSessionRef> live = const [];
  List<SavedProfile> profiles = const [];

  ConnectLinkRouter build(PendingLinkBridge bridge) => ConnectLinkRouter(
        bridge: bridge,
        loadProfiles: () async => profiles,
        liveSessions: () => live,
        setActive: activated.add,
        confirm: (p, verb) async {
          confirmed.add(p);
          confirmedVerbs.add(verb);
          return confirmAnswer;
        },
        confirmSend: (p, verb) async {
          confirmSends.add(verb.commandLine);
          return confirmSendAnswer;
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
        connectProfile: (p, verb) async {
          connected.add(p);
          connectedVerbs.add(verb);
        },
        sendVerb: (sid, verb) => sent.add('$sid ${verb.commandLine}'),
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

  group('R22/R23b/R25 tmux verb (#1149)', () {
    const verbLink =
        'mobissh://connect?host=box.example&user=alice&tmux=main';
    const cmd = 'tmux new-session -A -s main';

    test('fresh connect + verb + linkAutoConnect → no dialog, hand-off '
        'carries the typed verb', () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
      await router.deliver(verbLink);
      expect(spy.confirmed, isEmpty);
      expect(spy.confirmSends, isEmpty);
      expect(spy.sent, isEmpty);
      expect(spy.connected.single.identityKey, _alice.identityKey);
      expect(spy.connectedVerbs.single, isA<TmuxAttach>());
      expect(spy.connectedVerbs.single!.commandLine, cmd);
    });

    test('fresh connect + verb without linkAutoConnect → R12 confirmation '
        'names the command (R16)', () async {
      await router.deliver(verbLink);
      expect(spy.confirmed.single.identityKey, _alice.identityKey);
      expect(spy.confirmedVerbs.single!.commandLine, cmd);
      expect(spy.connectedVerbs.single!.commandLine, cmd);
    });

    test('no verb → hand-off carries null; R12 dialog gets no command',
        () async {
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.confirmedVerbs.single, isNull);
      expect(spy.connectedVerbs.single, isNull);
    });

    test('live same-identity session + verb → confirmSend names the '
        'command; Run sends once; linkAutoConnect does NOT skip it',
        () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      await router.deliver(verbLink);
      expect(spy.activated, ['alice-sid']);
      expect(spy.confirmed, isEmpty, reason: 'R13: auto-allowed, no R12');
      expect(spy.confirmSends, [cmd], reason: 'R23b: always asks when live');
      expect(spy.sent, ['alice-sid $cmd']);
      expect(spy.connected, isEmpty, reason: 'R17: focus, never reconnect');
    });

    test('live session + verb → Cancel sends nothing', () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      spy.confirmSendAnswer = false;
      await router.deliver(verbLink);
      expect(spy.activated, ['alice-sid']);
      expect(spy.confirmSends, [cmd]);
      expect(spy.sent, isEmpty);
      expect(spy.connected, isEmpty);
    });

    test('live session WITHOUT a verb → focus only, no confirmSend',
        () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.activated, ['alice-sid']);
      expect(spy.confirmSends, isEmpty);
      expect(spy.sent, isEmpty);
    });

    test('a live session of ANOTHER identity never receives the verb',
        () async {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
      spy.live = [
        LiveSessionRef(id: 'bob-sid', profileKey: _bob.identityKey),
      ];
      await router.deliver(verbLink);
      expect(spy.confirmSends, isEmpty);
      expect(spy.sent, isEmpty);
      expect(spy.connectedVerbs.single!.commandLine, cmd);
    });
  });
}
