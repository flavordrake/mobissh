// Riverpod providers exposing the xterm Terminal model + SshShell per-session.
//
// Phase 2.A (#501): one Terminal per `connected` lifecycle.
// Phase 4 (#511): keyed by sessionId. Each entry in `sessionsProvider` owns
// its own Terminal (created up-front in `SessionsNotifier.addOrActivate`).
// The shell provider is a `FutureProvider.family` keyed by sessionId so each
// session opens an independent PTY against its own SSHClient.
//
// Out of scope:
//   - Terminal model persistence across reconnects (Phase 2.D)
//   - Saved-session restoration on cold start (separate issue)

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_shell.dart';
import 'sessions.dart';

/// Function signature for opening a PTY-backed shell transport. The
/// production implementation reads the per-session `SSHClient` off the
/// matching `SessionEntry` controller and calls `client.shell(...)`. Widget
/// tests override this provider with a closure that returns a fake transport
/// without needing a real session.
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
  final entries = ref.read(sessionsProvider).entries;
  SshSessionController? controller;
  for (final e in entries) {
    if (e.id == sessionId) {
      controller = e.controller;
      break;
    }
  }
  final client = controller?.client;
  if (client == null) return null;
  return openSshShellTransport(client, terminal);
}

/// Test seam: override in `ProviderScope.overrides` to inject a fake
/// transport. Production sticks with the default (real `client.shell()`).
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

/// Opens (or returns the existing) PTY shell for [sessionId].
///
/// Watches the per-session controller's data stream so the shell is created
/// when the session reaches `connected` and torn down when it leaves.
final sshShellProvider =
    FutureProvider.family<SshShell?, String>((ref, sessionId) async {
  final entries = ref.watch(sessionsProvider).entries;
  SshSessionController? controller;
  Terminal? terminal;
  for (final e in entries) {
    if (e.id == sessionId) {
      controller = e.controller;
      terminal = e.terminal;
      break;
    }
  }
  if (controller == null || terminal == null) return null;

  // Watch session data — provider rebuilds when state transitions.
  final dataStream = ref.watch(_sessionDataStreamProvider(sessionId));
  final data = dataStream.valueOrNull;
  if (data == null || data.state != SshSessionState.connected) {
    return null;
  }
  final opener = ref.watch(sshShellOpenerProvider);
  final transport = await opener(ref, sessionId, terminal);
  if (transport == null) return null;
  final shell = SshShell(transport);
  shell.attach(terminal);

  ref.onDispose(shell.dispose);
  return shell;
});

/// Per-session data stream. Internal: powers `sshShellProvider` so it
/// rebuilds on state transitions.
final _sessionDataStreamProvider =
    StreamProvider.family<SshSessionData, String>((ref, sessionId) async* {
  final entries = ref.watch(sessionsProvider).entries;
  SshSessionController? controller;
  for (final e in entries) {
    if (e.id == sessionId) {
      controller = e.controller;
      break;
    }
  }
  if (controller == null) return;
  yield controller.data;
  yield* controller.stream;
});

/// Public per-session data accessor for the UI (tab strip + terminal screen).
final sessionDataProvider =
    StreamProvider.family<SshSessionData, String>((ref, sessionId) async* {
  final entries = ref.watch(sessionsProvider).entries;
  SshSessionController? controller;
  for (final e in entries) {
    if (e.id == sessionId) {
      controller = e.controller;
      break;
    }
  }
  if (controller == null) return;
  yield controller.data;
  yield* controller.stream;
});
