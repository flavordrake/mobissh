// Riverpod providers exposing the active SSH session to the UI layer.
//
// Phase 1 (#501): single global controller.
// Phase 4 (#511): the singleton has been replaced by `sessionsProvider`. The
// providers below are compat shims pointing at the *active* session in the
// collection so existing call sites (`connect_form.dart`, widget tests) keep
// working unchanged.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import 'sessions.dart';

/// Controller for the active session. Falls back to a transient idle
/// controller when no sessions exist yet so consumers don't have to null-check
/// before the first connect.
///
/// IMPORTANT: the fallback controller is a per-Container singleton; tests
/// that need a specific controller should populate `sessionsProvider` instead
/// (preferred) or override this provider directly.
final sshSessionControllerProvider = Provider<SshSessionController>((ref) {
  final entry = ref.watch(activeSessionEntryProvider);
  if (entry != null) return entry.controller;
  // Idle fallback. The ref keeps it alive only while there are no sessions;
  // once a real session is created, watchers re-resolve to entry.controller.
  final fallback = SshSessionController();
  ref.onDispose(fallback.dispose);
  return fallback;
});

/// Streams the active session's state to UI. Yields the controller snapshot
/// first so the UI sees a value before the next emit.
final sshSessionDataProvider = StreamProvider<SshSessionData>((ref) async* {
  final controller = ref.watch(sshSessionControllerProvider);
  yield controller.data;
  yield* controller.stream;
});
