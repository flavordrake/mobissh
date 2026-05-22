// Riverpod providers exposing the xterm Terminal model + SshShell to the UI.
//
// Phase 2.A (#501): one Terminal per `connected` lifecycle. When the SSH
// session transitions to `connected`, [sshShellProvider] opens a PTY shell
// against the active SSHClient and attaches it to the Terminal. When the
// session leaves `connected`, both are disposed.
//
// Out of scope (deferred):
//   - Multi-session terminals (Phase 4 foreground service)
//   - Terminal model persistence across reconnects (Phase 2.D)

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_shell.dart';
import 'connection_providers.dart';

/// Function signature for opening a PTY-backed shell transport. The
/// production implementation reads the active `SSHClient` off the
/// controller and calls `client.shell(...)`. Widget tests override this
/// provider with a closure that returns a fake transport without needing a
/// real session.
typedef SshShellOpener = Future<SshShellTransport?> Function(
  Ref ref,
  Terminal terminal,
);

Future<SshShellTransport?> _defaultShellOpener(
  Ref ref,
  Terminal terminal,
) async {
  final controller = ref.read(sshSessionControllerProvider);
  final client = controller.client;
  if (client == null) return null;
  return openSshShellTransport(client, terminal);
}

/// Test seam: override in `ProviderScope.overrides` to inject a fake
/// transport. Production sticks with the default (real `client.shell()`).
final sshShellOpenerProvider =
    Provider<SshShellOpener>((ref) => _defaultShellOpener);

/// Owns the [Terminal] model rendered by `TerminalView`. Recreated each time
/// the session enters `connected` (Phase 2.A — no reuse across reconnects).
final terminalProvider = Provider<Terminal>((ref) {
  final term = Terminal(maxLines: 5000);
  ref.onDispose(() {
    // Detach callbacks to avoid leaking into the next terminal.
    term.onOutput = null;
    term.onResize = null;
  });
  return term;
});

/// Opens (or returns the existing) PTY shell for the active SSH session.
///
/// Watches [sshSessionDataProvider] so the shell is created when the
/// session reaches `connected` and torn down when it leaves. Implemented as
/// a `FutureProvider` because `client.shell()` is async.
final sshShellProvider = FutureProvider<SshShell?>((ref) async {
  final data = ref.watch(sshSessionDataProvider).valueOrNull;
  if (data == null || data.state != SshSessionState.connected) {
    return null;
  }
  final terminal = ref.watch(terminalProvider);
  final opener = ref.watch(sshShellOpenerProvider);
  final transport = await opener(ref, terminal);
  if (transport == null) return null;
  final shell = SshShell(transport);
  shell.attach(terminal);

  // Disposal: if the provider is invalidated (e.g. session disconnects) or
  // the app shuts down, tear the shell down so the transport channel
  // closes and the byte pipe stops.
  ref.onDispose(shell.dispose);
  return shell;
});
