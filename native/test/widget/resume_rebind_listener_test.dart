// Resume-rebind listener wiring test (#551).
//
// `resumeRebindListenerProvider` must, on `AppLifecycleState.resumed`, rebind
// EVERY live session in `sessionsProvider` — not just the active one. This is
// the always-on counterpart to RootRouter's inline `ref.listen`, which dies
// when the router unmounts to show the terminal screen.
//
// We drive each proxy to `connected` by emitting an `SshStateEvent` from the
// task side of an in-memory gateway, flip `lifecycleProvider` to `resumed`,
// and assert that every proxy emitted a snapshot request (the observable side
// effect of `rebind()`) — proving the listener iterates the whole collection
// and is multi-session safe (uses ref.listen, not ref.watch of the active
// proxy).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/connection_providers.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/lifecycle_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resume rebinds every live session in the collection (#551)', () async {
    final pair = InMemoryGatewayPair();
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        // Avoid touching FlutterForegroundTask during addOrActivate.
        keepaliveServiceStarterProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(pair.dispose);

    // Activate the always-on listener.
    container.read(resumeRebindListenerProvider);

    // Create two sessions through the real notifier.
    final notifier = container.read(sessionsProvider.notifier);
    final e1 = notifier.addOrActivate(const SshConnectParams(
      host: 'h1',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    final e2 = notifier.addOrActivate(const SshConnectParams(
      host: 'h2',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));

    // Drive each proxy to `connected` via a task-side state event.
    for (final e in [e1, e2]) {
      pair.taskSide.send(SshStateEvent(
        sessionId: e.id,
        state: SshSessionState.connected.name,
        host: e.host,
        port: e.port,
        username: e.username,
      ).toJson());
    }
    // Let the gateway deliver the state events.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(e1.proxy.data.state, SshSessionState.connected);
    expect(e2.proxy.data.state, SshSessionState.connected);

    // Count snapshot requests arriving task-side (rebind() sends exactly one).
    final snapshotRequests = <String>[];
    final sub = pair.taskSide.incoming.listen((payload) {
      if (payload['kind'] == SshTaskCommandKind.requestSnapshot.name) {
        snapshotRequests.add(payload['sessionId'] as String);
      }
    });

    // Flip to resumed — the listener should rebind both sessions.
    container.read(lifecycleProvider.notifier).state =
        AppLifecycleState.resumed;
    // The provider only fires ref.listen on a CHANGE; default is resumed, so
    // bounce through paused first to guarantee a transition.
    container.read(lifecycleProvider.notifier).state =
        AppLifecycleState.paused;
    container.read(lifecycleProvider.notifier).state =
        AppLifecycleState.resumed;

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(snapshotRequests, containsAll([e1.id, e2.id]),
        reason: 'every live session must rebind on resume, not just active');

    await sub.cancel();
  });

  test('non-resumed lifecycle transitions do NOT rebind (#551)', () async {
    final pair = InMemoryGatewayPair();
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        keepaliveServiceStarterProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(pair.dispose);

    container.read(resumeRebindListenerProvider);
    final notifier = container.read(sessionsProvider.notifier);
    final e = notifier.addOrActivate(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    pair.taskSide.send(SshStateEvent(
      sessionId: e.id,
      state: SshSessionState.connected.name,
    ).toJson());
    await Future<void>.delayed(Duration.zero);

    final snapshotRequests = <String>[];
    final sub = pair.taskSide.incoming.listen((payload) {
      if (payload['kind'] == SshTaskCommandKind.requestSnapshot.name) {
        snapshotRequests.add(payload['sessionId'] as String);
      }
    });

    container.read(lifecycleProvider.notifier).state =
        AppLifecycleState.paused;
    container.read(lifecycleProvider.notifier).state =
        AppLifecycleState.inactive;
    await Future<void>.delayed(Duration.zero);

    expect(snapshotRequests, isEmpty,
        reason: 'only resumed triggers rebind');

    await sub.cancel();
  });
}
