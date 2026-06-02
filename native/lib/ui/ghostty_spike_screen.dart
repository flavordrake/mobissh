// SPIKE (#582, DO-NOT-MERGE): flterm / libghostty feasibility probe.
//
// Standalone debug screen that mounts the flterm TerminalView (powered by
// Ghostty's libghostty-vt native engine) WITHOUT touching the real session
// stack (terminal_screen.dart / sessions.dart are owned by Phase 2). It feeds
// static multi-line text — including a long URL and a wrapping paragraph — into
// the terminal and lets a human confirm three things on a real device:
//
//   1. RENDER       — the libghostty native .so loaded and the grid paints.
//   2. KEYBOARD      — tapping focuses the grid, the soft keyboard appears, and
//                      typed characters echo (we loop onOutput back into write).
//   3. DRAG-SELECT   — long-press + drag highlights cells; "Copy selection"
//                      pulls TerminalController.selectedText() to the clipboard.
//                      This is the WHOLE reason for the spike: xterm.dart v4 has
//                      no selection-extend API.
//
// Reachable only via the temporary debug FAB on the connect home page. Delete
// this file + the FAB when the spike concludes (GO → Phase 2 abstraction; or
// NO-GO → fork xterm.dart).

import 'dart:convert';

// flterm re-exports libghostty's `Key` input enum, which collides with
// Flutter's widget `Key`. We only use Flutter's, so hide flterm's.
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Sample content exercising wide layout, a long URL (OSC-8-free plain), and a
/// wrapping paragraph so we can verify soft-wrap selection on a narrow phone.
const _sampleText =
    'MobiSSH flterm/ghostty spike (#582)\r\n'
    '\r\n'
    'Long URL (try long-press + drag to select, then Copy selection):\r\n'
    'https://github.com/elias8/libghostty/releases/tag/libghostty-v0.0.9\r\n'
    '\r\n'
    'Paragraph (soft-wrap selection check): The quick brown fox jumps over '
    'the lazy dog while a second clause keeps going well past the right edge '
    'of a typical phone screen so the line must wrap and selection must follow '
    'the wrap boundary cleanly without dropping characters.\r\n'
    '\r\n'
    r'$ ls -la /usr/local/bin'
    '\r\n'
    'total 0  drwxr-xr-x  2 root root  4096 Jun  2 19:50 .\r\n'
    '\r\n'
    'Type below — characters echo locally (onOutput looped into write):\r\n'
    r'$ ';

class GhosttySpikeScreen extends StatefulWidget {
  const GhosttySpikeScreen({super.key});

  @override
  State<GhosttySpikeScreen> createState() => _GhosttySpikeScreenState();
}

class _GhosttySpikeScreenState extends State<GhosttySpikeScreen> {
  late final TerminalController _controller;
  String _status = 'initializing libghostty…';

  @override
  void initState() {
    super.initState();
    try {
      _controller = TerminalController();
      // Local echo: there's no PTY in the spike, so loop the terminal's own
      // output (keystrokes encoded by sendKey/sendText) straight back into the
      // grid. This proves the keyboard → libghostty → render path end to end.
      _controller.onOutput = (Uint8List bytes) {
        _controller.write(bytes);
      };
      _controller.write(Uint8List.fromList(utf8.encode(_sampleText)));
      _status = 'libghostty loaded — grid below should be painted';
    } catch (e, st) {
      // If the native .so failed to load (the make-or-break), surface it on
      // screen instead of a blank crash so the device tester can report it.
      _status = 'FAILED to init libghostty: $e\n$st';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copySelection() async {
    final text = _controller.selectedText();
    if (text.isEmpty) {
      _toast('No selection — long-press + drag the grid first.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast('Copied ${text.length} chars to clipboard.');
  }

  void _selectAll() {
    _controller.selectAll();
    _toast('selectAll() invoked — Copy selection to verify.');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flterm/ghostty spike (#582)'),
        actions: [
          IconButton(
            key: const Key('spike-select-all'),
            tooltip: 'Select all',
            icon: const Icon(Icons.select_all),
            onPressed: _selectAll,
          ),
          IconButton(
            key: const Key('spike-copy-selection'),
            tooltip: 'Copy selection',
            icon: const Icon(Icons.copy),
            onPressed: _copySelection,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _status,
              key: const Key('spike-status'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: TerminalView(
              key: const Key('spike-terminal-view'),
              controller: _controller,
              autofocus: true,
              theme: TerminalTheme.dark(),
              // Defaults already enable longPress + word + line + drag +
              // selectAll, but we name them explicitly so the spike intent is
              // legible: native touch drag-select is what we're proving.
              gestureSettings: const TerminalGestureSettings(
                enabledSelections: SelectionGesture.all,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
