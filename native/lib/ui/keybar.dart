// Bottom keybar widget (#518).
//
// Mirrors the PWA's key bar (Esc / Tab / / / - / | / ^C / ^Z / ^B / ^D, plus
// arrows / Home / End / PgUp / PgDn / ↵ / Paste / sticky Ctrl). Pressing a
// key forwards the configured byte sequence to the active session's terminal
// (xterm.dart) via `Terminal.textInput`, which routes through the standard
// keystroke pipe (see `keystroke_pipe_widget_test.dart`).
//
// Visibility is controlled by `keybarVisibleProvider` (SharedPreferences).
// The toggle lives in the session menu; this widget is just the renderer.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';

/// One key on the bar.
class KeybarKey {
  const KeybarKey({
    required this.id,
    required this.label,
    required this.sequence,
  });

  final String id;
  final String label;
  final String sequence;
}

/// Default key layout — same shape and order as the PWA's
/// `DEFAULT_KEY_BAR_CONFIG` in `src/modules/keybar-config.ts`.
const List<List<KeybarKey>> kDefaultKeybarRows = [
  [
    KeybarKey(id: 'keyEsc',   label: 'Esc',  sequence: '\x1b'),
    KeybarKey(id: 'keyTab',   label: '↹',    sequence: '\t'),
    KeybarKey(id: 'keySlash', label: '/',    sequence: '/'),
    KeybarKey(id: 'keyDash',  label: '-',    sequence: '-'),
    KeybarKey(id: 'keyPipe',  label: '|',    sequence: '|'),
    KeybarKey(id: 'keyCtrlC', label: '^C',   sequence: '\x03'),
    KeybarKey(id: 'keyCtrlZ', label: '^Z',   sequence: '\x1a'),
    KeybarKey(id: 'keyCtrlD', label: '^D',   sequence: '\x04'),
  ],
  [
    KeybarKey(id: 'keyLeft',  label: '◀',    sequence: '\x1b[D'),
    KeybarKey(id: 'keyUp',    label: '▲',    sequence: '\x1b[A'),
    KeybarKey(id: 'keyDown',  label: '▼',    sequence: '\x1b[B'),
    KeybarKey(id: 'keyRight', label: '▶',    sequence: '\x1b[C'),
    KeybarKey(id: 'keyHome',  label: 'Home', sequence: '\x1b[H'),
    KeybarKey(id: 'keyEnd',   label: 'End',  sequence: '\x1b[F'),
    KeybarKey(id: 'keyEnter', label: '↵',    sequence: '\r'),
    KeybarKey(id: 'keyPaste', label: '📋',   sequence: ''), // handled out-of-band
  ],
];

class Keybar extends ConsumerWidget {
  const Keybar({super.key, required this.activeEntry});

  final SessionEntry activeEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('keybar'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in kDefaultKeybarRows)
                _KeybarRow(
                  keys: row,
                  terminal: activeEntry.terminal,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeybarRow extends StatelessWidget {
  const _KeybarRow({required this.keys, required this.terminal});

  final List<KeybarKey> keys;
  final Terminal terminal;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final k in keys)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: _KeybarButton(
                keyData: k,
                terminal: terminal,
              ),
            ),
          ),
      ],
    );
  }
}

class _KeybarButton extends StatelessWidget {
  const _KeybarButton({required this.keyData, required this.terminal});

  final KeybarKey keyData;
  final Terminal terminal;

  Future<void> _onTap(BuildContext context) async {
    if (keyData.id == 'keyPaste') {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text != null && text.isNotEmpty) {
        terminal.textInput(text);
      }
      return;
    }
    terminal.textInput(keyData.sequence);
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: Key('keybar-btn-${keyData.id}'),
      onPressed: () => _onTap(context),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        keyData.label,
        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
