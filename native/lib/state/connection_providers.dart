// Riverpod providers exposing the active SSH session to the UI layer.
//
// Phase 1 (#501): single global controller.
// Phase 4 (#511): the singleton has been replaced by `sessionsProvider`. The
// providers below are compat shims pointing at the *active* session in the
// collection so existing call sites (`connect_form.dart`, widget tests) keep
// working unchanged.
// #533: shims resolve to the per-session [SshSessionProxy] instead of an
// in-UI `SshSessionController`. The proxy forwards commands across
// [TaskSshGateway] to a task-isolate-hosted `SessionHost`.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import 'lifecycle_providers.dart';
import 'session_host_providers.dart';
import 'sessions.dart';

/// Proxy for the active session. Falls back to a transient idle proxy when
/// no sessions exist yet so consumers don't have to null-check before the
/// first connect.
///
/// IMPORTANT: the fallback proxy is a per-Container singleton; tests that
/// need a specific proxy should populate `sessionsProvider` instead
/// (preferred) or override `taskSshGatewayProvider` directly.
final sshSessionProxyProvider = Provider<SshSessionProxy>((ref) {
  final entry = ref.watch(activeSessionEntryProvider);
  if (entry != null) return entry.proxy;
  // Idle fallback. The ref keeps it alive only while there are no sessions;
  // once a real session is created, watchers re-resolve to entry.proxy.
  final gateway = ref.watch(taskSshGatewayProvider);
  final fallback = SshSessionProxy(sessionId: '__idle__', gateway: gateway);
  ref.onDispose(fallback.dispose);
  return fallback;
});

/// Streams the active session's state to UI. Yields the proxy snapshot
/// first so the UI sees a value before the next emit.
final sshSessionDataProvider = StreamProvider<SshSessionData>((ref) async* {
  final proxy = ref.watch(sshSessionProxyProvider);
  yield proxy.data;
  yield* proxy.stream;
});

/// Always-on resume-rebind listener (#551).
///
/// `RootRouter` already rebinds proxies on `AppLifecycleState.resumed` — but
/// only while it is mounted. Once a session reaches `connected`, the router
/// swaps to `TerminalScreen` and unmounts, so a background→resume cycle on the
/// terminal screen would NOT trigger a rebind. This provider closes that gap:
/// read once near the app root, it lives for the lifetime of the
/// `ProviderContainer` and rebinds every live session whenever the app returns
/// to the foreground — no re-auth prompt, because creds are held task-side.
///
/// Multi-session safe: it uses `ref.listen` (NOT `ref.watch` of the active
/// proxy — that would be single-session and would rebuild on every active
/// switch). It reconciles over the whole `sessionsProvider` collection on each
/// resume, so a backgrounded non-active session rebinds alongside the active
/// one (project memory: `feedback_riverpod_watch_active_session`).
final resumeRebindListenerProvider = Provider<void>((ref) {
  ref.listen<AppLifecycleState>(lifecycleProvider, (prev, next) {
    if (next != AppLifecycleState.resumed) return;
    // Rebind every live session. The task-side `SessionHost` kept each SSH
    // client alive (foreground service + #517 transient reconnect); rebind
    // re-subscribes the UI proxy and re-emits its cached snapshot so the
    // terminal repaints within the 500ms budget (#524).
    for (final entry in ref.read(sessionsProvider).entries) {
      final state = entry.proxy.data.state;
      if (state == SshSessionState.connected ||
          state == SshSessionState.softDisconnected ||
          state == SshSessionState.reconnecting) {
        entry.proxy.rebind();
      }
    }
  });
});
