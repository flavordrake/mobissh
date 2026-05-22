// Full-screen terminal screen — rendered when the SSH session is in
// `connected` state.
//
// Phase 2.A (#501): minimal AppBar (host + user + disconnect) + xterm.dart
// `TerminalView`. Bottom safe-area padding so the on-screen nav doesn't
// cover the bottom shell row. The Terminal model and PTY shell are managed
// by terminal_providers.
//
// Out of scope (deferred to 2.B/2.C/2.D):
//   - Selection toolbar (long-press → copy)
//   - Tap-on-link overlays
//   - Pinch-to-zoom font sizing
//   - Tab bar / multi-session UI (Phase 4+)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/connection_providers.dart';
import '../state/terminal_providers.dart';

class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(sshSessionDataProvider).valueOrNull;
    final terminal = ref.watch(terminalProvider);
    // Drive the PTY shell open by watching its provider. The result is
    // intentionally ignored here — the shell wires itself into `terminal`
    // via `attach(...)`. We only watch for errors so the user sees them.
    final shellAsync = ref.watch(sshShellProvider);

    final hostLabel = data == null
        ? ''
        : '${data.username ?? ''}@${data.host ?? ''}:${data.port ?? ''}';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          hostLabel,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
        actions: [
          IconButton(
            key: const Key('terminal-disconnect-button'),
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: () =>
                ref.read(sshSessionControllerProvider).disconnect(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (shellAsync.hasError)
              Container(
                width: double.infinity,
                color: Colors.red.shade900,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  'Shell error: ${shellAsync.error}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            Expanded(
              child: TerminalView(
                terminal,
                key: const Key('terminal-view'),
                // Note: autofocus deferred until Phase 2.D — `autofocus: true`
                // opens a platform `TextInput` channel which hangs widget
                // tests (no IME present). Tap-to-focus works fine on real
                // devices; the auto-focus polish is a 2.D concern.
                autofocus: false,
                padding: const EdgeInsets.all(4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
