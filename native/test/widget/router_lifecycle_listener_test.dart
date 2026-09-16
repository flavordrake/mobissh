// RootRouter inline lifecycle listener backfill (#1162, coverage U4).
//
// RootRouter's `ref.listen(lifecycleProvider)` block is the ONLY place that
// (1) tells the task isolate the UI is backgrounded/foregrounded
// (`proxy.setActive`, #806/#840/#847/#936), (2) unbinds every proxy on pause
// (#533) and (3) consumes a pending attention focus / connect link on resume
// (#840 Slice 2, #1141 R18). `resumeRebindListenerProvider` (#551) shadows
// only the rebind half, so a regression here (setActive(false) dropped, the
// pending consume moved before the rebind, the wrong tab's host sent) passed
// the suite before these tests.
//
// Mounts the REAL RootRouter (same fixture as
// router_keeps_terminal_on_drop_test.dart), records every UI→task payload on
// the in-memory gateway and flips `lifecycleProvider` directly. Sessions stay
// IDLE on purpose: #551's listener rebinds connected/dropped sessions only, so
// every `requestSnapshot` recorded on resume is attributable to the inline
// listener alone. `unbind()` has no gateway side effect, so it is pinned
// functionally — a task-side state event must NOT reach `proxy.data` while
// paused and MUST after resume.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/main.dart';
import 'package:mobissh/platform/desktop.dart';
import 'package:mobissh/services/attention_focus_router.dart';
import 'package:mobissh/services/connect_link_router.dart';
import 'package:mobissh/services/session_attention_notification.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/attention_providers.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/lifecycle_providers.dart';
import 'package:mobissh/state/link_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

/// Counts `consumePending` calls; the bridge is empty so the real routing body
/// is a no-op after the count.
class _CountingAttentionRouter extends AttentionFocusRouter {
  _CountingAttentionRouter()
    : super(
        bridge: PendingFocusBridge(MapKeyValueStore()),
        setActive: (_) {},
        sessionExists: (_) => false,
        sendInput: (_, _) {},
      );

  int consumes = 0;

  @override
  Future<String?> consumePending() {
    consumes++;
    return super.consumePending();
  }
}

class _CountingLinkRouter extends ConnectLinkRouter {
  _CountingLinkRouter()
    : super(
        bridge: PendingLinkBridge(MapKeyValueStore()),
        loadProfiles: () async => const [],
        liveSessions: () => const [],
        setActive: (_) {},
        confirm: (_, _) async => null,
        confirmSend: (_, _) async => false,
        pick: (_) async => null,
        persistAutoConnect: (_) async {},
        connectProfile: (_, _) async {},
        sendVerb: (_, _) {},
        openCreate: (_) async {},
        reject: () {},
      );

  int consumes = 0;

  @override
  Future<void> consumePending() {
    consumes++;
    return super.consumePending();
  }
}

class _NoLinks implements LinkIntentSource {
  @override
  Stream<String> get links => const Stream<String>.empty();
}

class _Fixture {
  _Fixture(this.container, this.pair, this.attention, this.link);

  final ProviderContainer container;
  final InMemoryGatewayPair pair;
  final _CountingAttentionRouter attention;
  final _CountingLinkRouter link;

  /// Every UI→task payload, in send order.
  final List<Map<String, dynamic>> sent = [];

  List<Map<String, dynamic>> ofKind(SshTaskCommandKind kind) =>
      sent.where((p) => p['kind'] == kind.name).toList();

  void setLifecycle(AppLifecycleState state) {
    container.read(lifecycleProvider.notifier).state = state;
  }

  SessionEntry addSession(String host) {
    return container
        .read(sessionsProvider.notifier)
        .addOrActivate(
          SshConnectParams(
            host: host,
            port: 22,
            username: 'u',
            auth: const SshAuth.password('p'),
          ),
        );
  }

  /// Task → UI state event; reaches `proxy.data` only while the proxy is bound.
  void emitState(String id, SshSessionState state) {
    pair.taskSide.send(
      SshStateEvent(sessionId: id, state: state.name).toJson(),
    );
  }
}

_Fixture _makeFixture() {
  final pair = InMemoryGatewayPair();
  final attention = _CountingAttentionRouter();
  final link = _CountingLinkRouter();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      // NoopKeepaliveGateway path — keeps FlutterForegroundTask statics out of
      // the router's keepaliveControllerProvider read; also makes
      // attentionUiFlnInitProvider a no-op (in-process host).
      isDesktopProvider.overrideWithValue(true),
      keepaliveServiceStarterProvider.overrideWithValue(() async {}),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => FakeSshShellTransport(),
      ),
      attentionFocusRouterProvider.overrideWithValue(attention),
      connectLinkRouterProvider.overrideWithValue(link),
      linkIntentSourceProvider.overrideWithValue(_NoLinks()),
    ],
  );
  final f = _Fixture(container, pair, attention, link);
  final sub = pair.taskSide.incoming.listen(f.sent.add);
  addTearDown(() async {
    await sub.cancel();
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return f;
}

Future<void> _pump(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Mounts RootRouter, lets the cold-start consume settle, then clears the
/// payload record so each test asserts only what the lifecycle flip sends.
Future<void> _mount(WidgetTester tester, _Fixture f) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: const MaterialApp(home: RootRouter()),
    ),
  );
  await _pump(tester);
  f.sent.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RootRouter lifecycle listener (#1162)', () {
    testWidgets(
      'paused → ONE task-global setActive(false) carrying the front tab '
      'id + host, and every proxy is unbound (#806/#533/#936)',
      (tester) async {
        final f = _makeFixture();
        final e1 = f.addSession('h1');
        final e2 = f.addSession('h2');
        await _mount(tester, f);

        f.setLifecycle(AppLifecycleState.paused);
        await _pump(tester);

        final setActive = f.ofKind(SshTaskCommandKind.setActive);
        expect(
          setActive,
          hasLength(1),
          reason: 'setActive is task-global: exactly one send per transition',
        );
        expect(setActive.single['active'], isFalse);
        // addOrActivate makes the LAST added session active.
        expect(setActive.single['activeSessionId'], e2.id);
        expect(setActive.single['activeHost'], 'h2');
        expect(
          f.ofKind(SshTaskCommandKind.requestSnapshot),
          isEmpty,
          reason: 'pause must not rebind',
        );

        // (a) unbind on EVERY session: a task-side state event must not reach
        // either proxy while paused.
        f.emitState(e1.id, SshSessionState.connected);
        f.emitState(e2.id, SshSessionState.connected);
        await _pump(tester);
        expect(
          e1.proxy.data.state,
          SshSessionState.idle,
          reason: 'paused → e1 proxy unbound, event dropped',
        );
        expect(
          e2.proxy.data.state,
          SshSessionState.idle,
          reason: 'paused → e2 proxy unbound, event dropped',
        );
      },
    );

    testWidgets(
      'resumed → setActive(true) BEFORE rebind, and every proxy is rebound '
      '(#806/#524/#936)',
      (tester) async {
        final f = _makeFixture();
        final e1 = f.addSession('h1');
        final e2 = f.addSession('h2');
        await _mount(tester, f);

        f.setLifecycle(AppLifecycleState.paused);
        await _pump(tester);
        f.sent.clear();

        f.setLifecycle(AppLifecycleState.resumed);
        await _pump(tester);

        final setActive = f.ofKind(SshTaskCommandKind.setActive);
        expect(setActive, hasLength(1));
        expect(setActive.single['active'], isTrue);
        expect(setActive.single['activeSessionId'], e2.id);
        expect(setActive.single['activeHost'], 'h2');

        // (b) rebind on EVERY session — sessions are idle, so #551's listener
        // skips them and these requestSnapshot sends are the inline listener's.
        final snapshots = f
            .ofKind(SshTaskCommandKind.requestSnapshot)
            .map((p) => p['sessionId'])
            .toList();
        expect(snapshots, unorderedEquals([e1.id, e2.id]));

        // Ordering: the foreground signal lands before any per-proxy rebind so
        // the task restores its snapshot timer before the snapshot requests.
        final firstSetActive = f.sent.indexWhere(
          (p) => p['kind'] == SshTaskCommandKind.setActive.name,
        );
        final firstSnapshot = f.sent.indexWhere(
          (p) => p['kind'] == SshTaskCommandKind.requestSnapshot.name,
        );
        expect(
          firstSetActive,
          lessThan(firstSnapshot),
          reason: 'setActive(true) must precede rebind()',
        );

        // Rebound: task-side events flow to proxy.data again.
        f.emitState(e1.id, SshSessionState.connected);
        f.emitState(e2.id, SshSessionState.connected);
        await _pump(tester);
        expect(e1.proxy.data.state, SshSessionState.connected);
        expect(e2.proxy.data.state, SshSessionState.connected);
      },
    );

    testWidgets(
      'resumed → attention + link consumePending each called exactly once; '
      'paused consumes nothing (#840 Slice 2, #1141 R18)',
      (tester) async {
        final f = _makeFixture();
        f.addSession('h1');
        await _mount(tester, f);

        // Cold-start consume (initState post-frame) is one each.
        expect(f.attention.consumes, 1, reason: 'cold-start consume');
        expect(f.link.consumes, 1, reason: 'cold-start consume');

        f.setLifecycle(AppLifecycleState.paused);
        await _pump(tester);
        expect(f.attention.consumes, 1, reason: 'pause must not consume');
        expect(f.link.consumes, 1, reason: 'pause must not consume');

        f.setLifecycle(AppLifecycleState.resumed);
        await _pump(tester);
        expect(f.attention.consumes, 2, reason: 'resume consumes once');
        expect(f.link.consumes, 2, reason: 'resume consumes once');

        // inactive → resumed is not a pause/resume edge the router acts on
        // beyond `resumed` itself: a second resume consumes again, exactly once.
        f.setLifecycle(AppLifecycleState.inactive);
        await _pump(tester);
        expect(f.attention.consumes, 2);
        expect(f.link.consumes, 2);
        f.setLifecycle(AppLifecycleState.resumed);
        await _pump(tester);
        expect(f.attention.consumes, 3);
        expect(f.link.consumes, 3);
      },
    );

    testWidgets(
      'with 2 sessions the FRONT tab (after a tab switch) is the id/host '
      'sent on pause AND resume, not the last-added one (#936/#847)',
      (tester) async {
        final f = _makeFixture();
        final e1 = f.addSession('h1');
        f.addSession('h2');
        await _mount(tester, f);

        // Tab switch to e1. The #847 foreground listener sends its own
        // setActive(true) for this change; clear it so the assertions below
        // see only the lifecycle sends.
        f.container.read(sessionsProvider.notifier).setActive(e1.id);
        await _pump(tester);
        f.sent.clear();

        f.setLifecycle(AppLifecycleState.paused);
        await _pump(tester);
        var setActive = f.ofKind(SshTaskCommandKind.setActive);
        expect(setActive, hasLength(1));
        expect(setActive.single['active'], isFalse);
        expect(setActive.single['activeSessionId'], e1.id);
        expect(setActive.single['activeHost'], 'h1');

        f.sent.clear();
        f.setLifecycle(AppLifecycleState.resumed);
        await _pump(tester);
        setActive = f.ofKind(SshTaskCommandKind.setActive);
        expect(setActive, hasLength(1));
        expect(setActive.single['active'], isTrue);
        expect(setActive.single['activeSessionId'], e1.id);
        expect(setActive.single['activeHost'], 'h1');
      },
    );

    testWidgets(
      'front tab id/host survive the front session being disconnected '
      '(#936: frontActiveId, not `active`)',
      (tester) async {
        final f = _makeFixture();
        final e1 = f.addSession('h1');
        f.addSession('h2');
        await _mount(tester, f);
        f.container.read(sessionsProvider.notifier).setActive(e1.id);
        await _pump(tester);
        // Drive the FRONT session to `disconnected` while bound.
        f.emitState(e1.id, SshSessionState.disconnected);
        await _pump(tester);
        expect(e1.proxy.data.state, SshSessionState.disconnected);
        f.sent.clear();

        f.setLifecycle(AppLifecycleState.paused);
        await _pump(tester);
        final setActive = f.ofKind(SshTaskCommandKind.setActive);
        expect(setActive, hasLength(1));
        expect(
          setActive.single['activeSessionId'],
          e1.id,
          reason: 'a disconnected front tab still names itself (#936)',
        );
        expect(setActive.single['activeHost'], 'h1');
      },
    );

    testWidgets(
      'no session → pause/resume send nothing to the task, do not throw, and '
      'the pending consumers still run on resume',
      (tester) async {
        final f = _makeFixture();
        await _mount(tester, f);
        expect(f.attention.consumes, 1);
        expect(f.link.consumes, 1);

        f.setLifecycle(AppLifecycleState.paused);
        await _pump(tester);
        f.setLifecycle(AppLifecycleState.resumed);
        await _pump(tester);

        // The listener guards `entries.isNotEmpty` before `proxy.setActive`:
        // with no proxy there is nothing to send on, so the gateway stays
        // silent (the issue's "(e) still setActive called" is not what the
        // code does — there is no proxy to call it on).
        expect(f.sent, isEmpty, reason: 'no proxy → no gateway traffic');
        expect(tester.takeException(), isNull);
        expect(f.attention.consumes, 2);
        expect(f.link.consumes, 2);
        // Still on the chooser.
        expect(find.byType(ConnectHomePage), findsOneWidget);
      },
    );
  });
}
