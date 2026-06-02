// Ghostty (flterm / libghostty-vt) session terminal view (#684, #582).
//
// The OPT-IN alternate to the xterm.dart `TerminalView` rendered by
// `_SessionTerminalBody` in terminal_screen.dart. Selected via the persisted
// `terminalBackendProvider` (TerminalBackend.ghostty); the xterm path stays the
// default and is untouched.
//
// Why flterm: libghostty-vt gives NATIVE touch drag-select + copy, which
// xterm.dart v4 lacks (no selection-extend API — #582). This widget wires an
// flterm `TerminalController` to the SAME live session I/O the xterm path uses:
//
//   proxy.output (PTY bytes)        -> controller.write(bytes)
//   controller.onOutput (keystrokes)-> proxy.sendInput(bytes)   [gated: connected]
//   controller.onResize (cols,rows) -> proxy.sendResize(cols, rows)
//
// MVP scope (#684): render a real session + input + resize + drag-select-copy.
// Per-session font/theme/size parity for the ghostty backend is a FOLLOW-UP —
// this view uses flterm's bundled dark theme. The xterm path keeps the
// per-session theme/font/size (#601/#571/#679); ghostty parity is deferred.
//
// flterm re-exports libghostty's `Key` input enum, which collides with
// Flutter's widget `Key`. We only use Flutter's, so hide flterm's.

import 'dart:async';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'top_toast.dart';

/// A session terminal rendered with flterm (libghostty). Wires the active
/// session's proxy I/O to an flterm [TerminalController] and exposes a copy
/// button that pulls the native drag-selection to the clipboard (#684).
class GhosttyTerminalView extends ConsumerStatefulWidget {
  const GhosttyTerminalView({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<GhosttyTerminalView> createState() =>
      _GhosttyTerminalViewState();
}

class _GhosttyTerminalViewState extends ConsumerState<GhosttyTerminalView> {
  TerminalController? _controller;

  /// PTY output (bytes) -> controller.write subscription. Cancelled on dispose.
  StreamSubscription<Uint8List>? _outputSub;

  String? _initError;

  @override
  void initState() {
    super.initState();
    final proxy = _resolveProxy();
    if (proxy == null) {
      _initError = 'No session for ${widget.sessionId}';
      return;
    }
    try {
      final controller = TerminalController();
      // Keystrokes (controller.onOutput) -> SSH stdin. Gate on a LIVE session,
      // mirroring the xterm path in sessions.dart: a dead PTY drops input
      // rather than landing escape/mouse bytes as literal text on a re-opened
      // shell.
      controller.onOutput = (bytes) {
        if (proxy.data.state != SshSessionState.connected) return;
        proxy.sendInput(bytes);
      };
      // Grid resize -> PTY resize. flterm reports (cols, rows); the proxy's
      // pixel sizes default to 0 (the task isolate only needs cols/rows).
      controller.onResize = (cols, rows) {
        proxy.sendResize(cols, rows);
      };
      // PTY output bytes -> terminal. The subscription lives on this state so
      // dispose() cancels it.
      _outputSub = proxy.output.listen((bytes) {
        try {
          controller.write(bytes);
        } catch (_) {
          // Defensive — a single PTY byte must never crash the session.
        }
      });
      _controller = controller;
    } catch (e) {
      // If libghostty's native .so failed to load, surface it instead of a
      // blank crash so the device tester can report it (mirrors the spike).
      _initError = 'flterm init failed: $e';
    }
  }

  SshSessionProxy? _resolveProxy() {
    for (final e in ref.read(sessionsProvider).entries) {
      if (e.id == widget.sessionId) return e.proxy;
    }
    return null;
  }

  Future<void> _copySelection() async {
    final controller = _controller;
    if (controller == null) return;
    final text = controller.selectedText();
    if (text.isEmpty) {
      if (mounted) {
        showTopToast(context, 'No selection — drag across the terminal first.');
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTopToast(context, 'Copied ${text.length} chars');
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _controller?.onOutput = null;
    _controller?.onResize = null;
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Container(
        key: const Key('ghostty-terminal-error'),
        color: Colors.red.shade900,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          _initError ?? 'flterm unavailable',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      );
    }
    return Stack(
      key: Key('ghostty-terminal-${widget.sessionId}'),
      children: [
        Positioned.fill(
          child: TerminalView(
            controller: controller,
            autofocus: false,
            theme: TerminalTheme.dark(),
            padding: const EdgeInsets.all(4),
            // Native touch drag-select + word/line select + select-all — the
            // whole reason for the ghostty backend (#582). xterm.dart v4 can't.
            gestureSettings: const TerminalGestureSettings(
              enabledSelections: SelectionGesture.all,
            ),
          ),
        ),
        // Copy-selection affordance. flterm's drag-select highlights cells; this
        // pulls `selectedText()` to the clipboard with a top-toast confirmation.
        Positioned(
          right: 4,
          bottom: 4,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: IconButton(
              key: const Key('ghostty-copy-selection'),
              tooltip: 'Copy selection',
              iconSize: 18,
              icon: const Icon(Icons.copy, color: Colors.white),
              onPressed: _copySelection,
            ),
          ),
        ),
      ],
    );
  }
}
