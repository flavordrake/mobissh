// Bottom keybar widget (#518).
//
// Mirrors the PWA's key bar (Esc / Tab / / / - / | / ^C / ^Z / ^D, plus
// arrows / Home / End / ↵ / Paste). Pressing a key forwards the configured
// byte sequence to the active session's terminal (xterm.dart) via
// `Terminal.textInput`, which routes through the standard keystroke pipe
// (see `keystroke_pipe_widget_test.dart`).
//
// Layout (owner feedback 2026-06-01): ONE LINE of touch-friendly buttons that
// scrolls horizontally — not stacked rows. Terminal real estate is premium.
// Icons are stylized MONOCHROME glyphs / Material icons that tint with the
// theme — never colorful emoji (the Paste key was a 📋 emoji; now a
// theme-tinted Icons.content_paste). See memory feedback_monochrome_icons_no_emoji.
//
// Visibility is controlled by `keybarVisibleProvider` (SharedPreferences).
// The toggle lives in the session menu; this widget is just the renderer.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/sessions.dart';

/// One key on the bar. Renders [label] text, OR [icon] (a monochrome
/// theme-tinted Material icon) when set — never an emoji.
class KeybarKey {
  const KeybarKey({
    required this.id,
    required this.label,
    required this.sequence,
    this.icon,
  });

  final String id;
  final String label;
  final String sequence;

  /// When non-null, the button shows this monochrome icon instead of [label]
  /// text (e.g. Paste). [label] is still used as the accessibility tooltip.
  final IconData? icon;
}

/// Default key layout — one flat line (scrolls horizontally), same key set and
/// order as the PWA's `DEFAULT_KEY_BAR_CONFIG` in `src/modules/keybar-config.ts`.
const List<KeybarKey> kDefaultKeybarKeys = [
  KeybarKey(id: 'keyEsc', label: 'Esc', sequence: '\x1b'),
  KeybarKey(id: 'keyTab', label: '↹', sequence: '\t'),
  KeybarKey(id: 'keySlash', label: '/', sequence: '/'),
  KeybarKey(id: 'keyDash', label: '-', sequence: '-'),
  KeybarKey(id: 'keyPipe', label: '|', sequence: '|'),
  KeybarKey(id: 'keyCtrlC', label: '^C', sequence: '\x03'),
  KeybarKey(id: 'keyCtrlZ', label: '^Z', sequence: '\x1a'),
  KeybarKey(id: 'keyCtrlD', label: '^D', sequence: '\x04'),
  KeybarKey(id: 'keyLeft', label: '◀', sequence: '\x1b[D'),
  KeybarKey(id: 'keyUp', label: '▲', sequence: '\x1b[A'),
  KeybarKey(id: 'keyDown', label: '▼', sequence: '\x1b[B'),
  KeybarKey(id: 'keyRight', label: '▶', sequence: '\x1b[C'),
  KeybarKey(id: 'keyHome', label: 'Home', sequence: '\x1b[H'),
  KeybarKey(id: 'keyEnd', label: 'End', sequence: '\x1b[F'),
  KeybarKey(id: 'keyEnter', label: '↵', sequence: '\r'),
  KeybarKey(
    id: 'keyPaste',
    label: 'Paste',
    sequence: '', // handled out-of-band
    icon: Icons.content_paste,
  ),
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
        // ONE LINE that scrolls horizontally (owner 2026-06-01). 16 keys can't
        // fit a phone width at a touch-friendly size, so the row scrolls rather
        // than stacking into a second line or shrinking buttons below the tap
        // target. Each button has a comfortable min width.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in kDefaultKeybarKeys)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _KeybarButton(
                    keyData: k,
                    terminal: activeEntry.terminal,
                  ),
                ),
            ],
          ),
        ),
      ),
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
    final theme = Theme.of(context);
    // Monochrome icon (theme-tinted) when set, else the label glyph/text.
    // Never an emoji — see memory feedback_monochrome_icons_no_emoji.
    final Widget child = keyData.icon != null
        ? Icon(
            keyData.icon,
            size: 18,
            color: theme.colorScheme.onSurface,
            semanticLabel: keyData.label,
          )
        : Text(
            keyData.label,
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
            overflow: TextOverflow.ellipsis,
          );
    return OutlinedButton(
      key: Key('keybar-btn-${keyData.id}'),
      onPressed: () => _onTap(context),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        // Touch-friendly: a comfortable min width/height per key (≥44px tall
        // tap target) instead of squeezing N keys to fit the viewport width.
        minimumSize: const Size(48, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: child,
    );
  }
}
