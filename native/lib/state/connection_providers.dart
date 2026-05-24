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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
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
