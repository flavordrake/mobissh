// Riverpod providers exposing the xterm Terminal model per-session.
//
// Phase 2.A (#501): one Terminal per `connected` lifecycle.
// Phase 4 (#511): keyed by sessionId. Each entry in `sessionsProvider` owns
// its own Terminal (created up-front in `SessionsNotifier.addOrActivate`).
// #533: per-session PTY output now flows from [SshSessionProxy.output] →
// `Terminal.write` directly inside `SessionsNotifier.addOrActivate`. The
// in-UI `SshShell` path is no longer used in production because the
// `SSHClient` lives in the task isolate. The shell-opener provider stays as
// a test seam — widget tests that want to drive byte sequences into the
// terminal through a fake transport still register one — but production
// resolves `sshShellProvider` to null.
//
// Out of scope:
//   - Terminal model persistence across reconnects (Phase 2.D)
//   - Saved-session restoration on cold start (separate issue)

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_shell.dart';
import 'sessions.dart';

/// Function signature for opening a PTY-backed shell transport. Production
/// no longer uses this path (#533) — PTY bytes arrive across the task
/// isolate via [SshSessionProxy.output]. Widget tests that need to push
/// bytes through a fake transport keep using this seam.
typedef SshShellOpener = Future<SshShellTransport?> Function(
  Ref ref,
  String sessionId,
  Terminal terminal,
);

Future<SshShellTransport?> _defaultShellOpener(
  Ref ref,
  String sessionId,
  Terminal terminal,
) async {
  // Production path: PTY bytes flow through the proxy → terminal subscription
  // wired in `SessionsNotifier.addOrActivate`. No local SSHClient to open a
  // shell on.
  return null;
}

/// Test seam: override in `ProviderScope.overrides` to inject a fake
/// transport. Production returns null (#533); the PTY pipe lives in the
/// task isolate.
final sshShellOpenerProvider =
    Provider<SshShellOpener>((ref) => _defaultShellOpener);

/// Per-session [Terminal] model. Reads from the session collection so the
/// terminal lifetime matches the entry lifetime (created in
/// `SessionsNotifier.addOrActivate`, disposed in `close`).
final terminalProvider = Provider.family<Terminal, String>((ref, sessionId) {
  final entries = ref.watch(sessionsProvider).entries;
  for (final e in entries) {
    if (e.id == sessionId) return e.terminal;
  }
  // Fallback terminal so the type contract holds. In practice consumers
  // shouldn't request a terminal for a missing session.
  return Terminal(maxLines: 5000);
});

/// Opens (or returns the existing) PTY shell for [sessionId] via the test
/// seam. Production resolves to null (#533) — the task isolate owns the
/// `SSHClient` and PTY bytes flow across the gateway to the proxy.
///
/// Watches the per-session proxy's data stream so the shell is created
/// when the session reaches `connected` (in tests).
final sshShellProvider =
    FutureProvider.family<SshShell?, String>((ref, sessionId) async {
  final entries = ref.watch(sessionsProvider).entries;
  SessionEntry? entry;
  for (final e in entries) {
    if (e.id == sessionId) {
      entry = e;
      break;
    }
  }
  if (entry == null) return null;

  // Watch session data — provider rebuilds when state transitions.
  final dataStream = ref.watch(_sessionDataStreamProvider(sessionId));
  final data = dataStream.valueOrNull;
  if (data == null || data.state != SshSessionState.connected) {
    return null;
  }
  final opener = ref.watch(sshShellOpenerProvider);
  final transport = await opener(ref, sessionId, entry.terminal);
  if (transport == null) return null;
  final shell = SshShell(transport);
  shell.attach(entry.terminal);

  ref.onDispose(shell.dispose);
  return shell;
});

/// Per-session data stream. Internal: powers `sshShellProvider` so it
/// rebuilds on state transitions.
final _sessionDataStreamProvider =
    StreamProvider.family<SshSessionData, String>((ref, sessionId) async* {
  final entries = ref.watch(sessionsProvider).entries;
  SessionEntry? entry;
  for (final e in entries) {
    if (e.id == sessionId) {
      entry = e;
      break;
    }
  }
  if (entry == null) return;
  yield entry.proxy.data;
  yield* entry.proxy.stream;
});

/// Public per-session data accessor for the UI (tab strip + terminal screen).
final sessionDataProvider =
    StreamProvider.family<SshSessionData, String>((ref, sessionId) async* {
  final entries = ref.watch(sessionsProvider).entries;
  SessionEntry? entry;
  for (final e in entries) {
    if (e.id == sessionId) {
      entry = e;
      break;
    }
  }
  if (entry == null) return;
  yield entry.proxy.data;
  yield* entry.proxy.stream;
});
