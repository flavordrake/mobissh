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

import 'dart:async';

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
  // #1211: window selections (`sid session:window`) and the ORDER of every
  // send/select, so "select after attach" is asserted, not assumed.
  final List<String> selects = [];
  final List<String> order = [];
  Set<String> attached = {}; // `sid session` pairs the app attached via a link
  int rejections = 0;
  LinkConfirmChoice? confirmAnswer = LinkConfirmChoice.once;
  // #1279 G1: when set, the confirm dialog stays open until completed.
  Completer<LinkConfirmChoice?>? confirmGate;
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
          final gate = confirmGate;
          if (gate != null) return gate.future;
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
        sendVerb: (sid, verb) {
          sent.add('$sid ${verb.commandLine}');
          order.add('send');
        },
        isTmuxAttached: (sid, name) => attached.contains('$sid $name'),
        selectWindow: (sid, verb) async {
          selects.add('$sid ${verb.name}:${verb.window}');
          order.add('select');
        },
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

  group('#1211 window= routing', () {
    const windowLink =
        'mobissh://connect?host=box.example&user=alice&tmux=main&window=beta';
    const cmd = 'tmux new-session -A -s main';

    setUp(() {
      spy.profiles = [_alice.copyWith(linkAutoConnect: true), _bob];
    });

    test('fresh connect → the hand-off carries the window; the router itself '
        'selects nothing (the connect path selects after the attach)',
        () async {
      await router.deliver(windowLink);
      final verb = spy.connectedVerbs.single! as TmuxAttach;
      expect(verb.commandLine, cmd);
      expect(verb.window, 'beta');
      expect(spy.selects, isEmpty);
      expect(spy.sent, isEmpty);
    });

    test('live session already attached to that tmux session → select only: '
        'no confirm, no second attach', () async {
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      spy.attached = {'alice-sid main'};
      await router.deliver(windowLink);
      expect(spy.activated, ['alice-sid']);
      expect(spy.confirmSends, isEmpty, reason: 'nothing is typed, so no R23');
      expect(spy.sent, isEmpty, reason: 'no second attach');
      expect(spy.selects, ['alice-sid main:beta']);
      expect(spy.connected, isEmpty);
    });

    test('live session attached to ANOTHER tmux session → R23 confirm; Run '
        'attaches, THEN selects', () async {
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      spy.attached = {'alice-sid other'};
      await router.deliver(windowLink);
      expect(spy.confirmSends, [cmd]);
      expect(spy.sent, ['alice-sid $cmd']);
      expect(spy.selects, ['alice-sid main:beta']);
      expect(spy.order, ['send', 'select']);
    });

    test('live session, R23 cancelled → neither attach nor select', () async {
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      spy.confirmSendAnswer = false;
      await router.deliver(windowLink);
      expect(spy.sent, isEmpty);
      expect(spy.selects, isEmpty);
    });

    test('live session + tmux= WITHOUT window= → unchanged: confirm + send, '
        'no select even when attached', () async {
      spy.live = [
        LiveSessionRef(id: 'alice-sid', profileKey: _alice.identityKey),
      ];
      spy.attached = {'alice-sid main'};
      await router.deliver(
          'mobissh://connect?host=box.example&user=alice&tmux=main');
      expect(spy.confirmSends, [cmd]);
      expect(spy.sent, ['alice-sid $cmd']);
      expect(spy.selects, isEmpty);
    });

    test('the window survives the process-death pending record', () async {
      final bridge = PendingLinkBridge(store);
      await bridge.setPending(const ConnectRequest(
        verb: ConnectVerb.connect,
        host: 'box.example',
        user: 'alice',
        tmux: 'main',
        window: 'beta',
      ));
      await router.consumePending();
      expect((spy.connectedVerbs.single! as TmuxAttach).window, 'beta');
      expect(spy.log.join('\n'), isNot(contains('beta')));
    });
  });

  // #1279 G1 / F8: at most one link in flight. A link that arrives while one
  // is being confirmed is DROPPED — never stacked, never swapped in under the
  // user's tap — and leaves no banner and no pending record behind.
  group('G1 one link in flight', () {
    test('a burst of three shows one confirm; two are dropped as busy',
        () async {
      spy.confirmGate = Completer<LinkConfirmChoice?>();
      final first =
          router.deliver('mobissh://connect?host=box.example&user=alice');
      await pumpEventQueue();
      await router.deliver('mobissh://connect?host=box.example&user=bob');
      await router.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.confirmed.map((p) => p.identityKey), [_alice.identityKey]);
      expect(spy.log.where((l) => l.contains('dropped reason=busy')).length,
          2);
      expect(spy.rejections, 0, reason: 'a dropped link shows no banner');

      spy.confirmGate!.complete(LinkConfirmChoice.once);
      await first;
      expect(spy.connected.map((p) => p.identityKey), [_alice.identityKey],
          reason: 'the pending link was not replaced by a later one');
      expect(await store.getString('mobissh.link.pending'), isNull);
    });

    test('a rejected link during a confirm is dropped, not bannered',
        () async {
      spy.confirmGate = Completer<LinkConfirmChoice?>();
      final first =
          router.deliver('mobissh://connect?host=box.example&user=alice');
      await pumpEventQueue();
      await router.deliver('mobissh://nope');
      expect(spy.rejections, 0);
      spy.confirmGate!.complete(null);
      await first;
    });

    test('the guard is released after a link completes or a seam throws',
        () async {
      spy.confirmGate = Completer<LinkConfirmChoice?>();
      final first =
          router.deliver('mobissh://connect?host=box.example&user=alice');
      await pumpEventQueue();
      spy.confirmGate!.completeError(StateError('dialog torn down'));
      await expectLater(first, throwsStateError);

      spy.confirmGate = null;
      await router.deliver('mobissh://connect?host=box.example&user=bob');
      expect(spy.connected.map((p) => p.identityKey), [_bob.identityKey]);
    });

    test('an open create editor holds the guard until it closes', () async {
      final editor = Completer<void>();
      final r = ConnectLinkRouter(
        bridge: PendingLinkBridge(store),
        loadProfiles: () async => spy.profiles,
        liveSessions: () => const [],
        setActive: (_) {},
        confirm: (_, _) async => LinkConfirmChoice.once,
        confirmSend: (_, _) async => false,
        pick: (_) async => null,
        persistAutoConnect: (_) async {},
        connectProfile: (p, _) async => spy.connected.add(p),
        sendVerb: (_, _) {},
        isTmuxAttached: (_, _) => false,
        selectWindow: (_, _) async {},
        openCreate: (p) => editor.future,
        reject: () => spy.rejections++,
        log: (where, msg) => spy.log.add('$where: $msg'),
      );
      final first = r.deliver('mobissh://connect?host=unknown.example');
      await pumpEventQueue();
      await r.deliver('mobissh://connect?host=box.example&user=alice');
      expect(spy.connected, isEmpty);
      expect(spy.log.where((l) => l.contains('dropped reason=busy')), hasLength(1));
      editor.complete();
      await first;
    });
  });

  // #1279 S1: the parser accepts sftp links, but routing them is S2. Until
  // then an sftp request must NOT degrade into a plain connect that drops the
  // path (the G3 failure mode) — it is rejected.
  group('S1 sftp links are not routed yet', () {
    for (final link in [
      'sftp://alice@box.example/home/alice',
      'mobissh://sftp?host=box.example&user=alice&path=/x',
    ]) {
      test(link, () async {
        spy.profiles = [_alice.copyWith(linkAutoConnect: true)];
        await router.deliver(link);
        expect(spy.connected, isEmpty);
        expect(spy.confirmed, isEmpty);
        expect(spy.created, isEmpty);
        expect(spy.rejections, 1);
        expect(spy.log.join('\n'), isNot(contains('alice')));
      });
    }

    test('the pending record carries the validated path', () async {
      final bridge = PendingLinkBridge(store);
      await bridge.setPending(const ConnectRequest(
        verb: ConnectVerb.sftp,
        host: 'box.example',
        path: '~/x',
      ));
      final back = await bridge.readPending();
      expect(back?.verb, ConnectVerb.sftp);
      expect(back?.path, '~/x');
    });
  });
}
