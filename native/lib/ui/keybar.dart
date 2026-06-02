// Bottom keybar widget (#518).
//
// Mirrors the PWA's key bar (Esc / Tab / / / - / | / ^C / ^Z / ^D, plus
// arrows / Home / End / Enter / Paste). Pressing a key forwards the configured
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

/// Bottom-chrome sizing (#615). The keybar was shrunk ~25% vertically to give
/// the terminal more real estate. These are the single source of truth for the
/// button geometry AND the vertical space the bar occupies — the latter
/// ([kKeybarReserve]) is consumed by the compose bar's bottom reserve in
/// terminal_screen.dart so a docked compose panel always clears the chrome.
///
/// Old values (pre-#615): minWidth 48, minHeight 44, icon 18, label 14,
/// reserve ≈ 96. The ~25% reduction lands the height around 33 and the reserve
/// around 72.
const double kKeybarButtonMinWidth = 44;
const double kKeybarButtonMinHeight = 33;
const double kKeybarIconSize = 14;
const double kKeybarLabelFontSize = 12;

/// "ESC" is the widest text label; scaling it down lets it share the normal
/// button min width instead of bulging the bar (#615). Still monochrome text —
/// no glyph that could be mistaken for Enter.
const double kKeybarEscFontSize = 10;

/// Vertical space (logical px) the keybar occupies, used as the compose-bar
/// bottom reserve. Button height + the 4px top/bottom scroll-view padding,
/// rounded for a small safety margin. ~25% smaller than the old hardcoded 96.
const double kKeybarReserve = 72;

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

/// Default key layout — one flat line (scrolls horizontally), mirroring the
/// PWA's `DEFAULT_KEY_BAR_CONFIG` (src/modules/keybar-config.ts) as the
/// AUTHORITATIVE key SET.
///
/// ORDER CONTRACT (do not regress — this keeps drifting): navigation and
/// symbol keys come FIRST, and the control sequences (^C / ^Z / ^B / ^D) are
/// grouped LAST at the END of the bar. The PWA config is the spec for which
/// keys exist; the control-keys-last grouping is owner-mandated (repeat
/// correction). If you add a control sequence, append it to the control group
/// at the end — never interspersed among the nav/symbol keys.
///
/// All four arrows use monochrome Material `Icon`s (theme-tinted via the
/// [KeybarKey.icon] path) instead of the unicode ◀▲▼▶ glyphs, which the
/// platform colorizes inconsistently (emoji-style fills). No colorful/emoji
/// glyphs — see memory feedback_monochrome_icons_no_emoji.
const List<KeybarKey> kDefaultKeybarKeys = [
  // --- nav / symbol keys first ---
  KeybarKey(id: 'keyEsc', label: 'Esc', sequence: '\x1b'),
  KeybarKey(id: 'keyTab', label: '↹', sequence: '\t'),
  KeybarKey(id: 'keySlash', label: '/', sequence: '/'),
  KeybarKey(id: 'keyDash', label: '-', sequence: '-'),
  KeybarKey(id: 'keyPipe', label: '|', sequence: '|'),
  KeybarKey(
    id: 'keyLeft',
    label: 'Left',
    sequence: '\x1b[D',
    icon: Icons.keyboard_arrow_left,
  ),
  KeybarKey(
    id: 'keyUp',
    label: 'Up',
    sequence: '\x1b[A',
    icon: Icons.keyboard_arrow_up,
  ),
  KeybarKey(
    id: 'keyDown',
    label: 'Down',
    sequence: '\x1b[B',
    icon: Icons.keyboard_arrow_down,
  ),
  KeybarKey(
    id: 'keyRight',
    label: 'Right',
    sequence: '\x1b[C',
    icon: Icons.keyboard_arrow_right,
  ),
  KeybarKey(id: 'keyHome', label: 'Home', sequence: '\x1b[H'),
  KeybarKey(id: 'keyEnd', label: 'End', sequence: '\x1b[F'),
  KeybarKey(id: 'keyPgUp', label: 'PgUp', sequence: '\x1b[5~'),
  KeybarKey(id: 'keyPgDn', label: 'PgDn', sequence: '\x1b[6~'),
  // #650: was `label: '↵'` (U+21B5), which renders as tofu in the bundled
  // font — the SAME issue the arrows had. Use the monochrome Material icon
  // path (Icons.keyboard_return) so it's clearly an Enter/Return key. The tap
  // wiring still forwards `sequence` ('\r') regardless of the icon path.
  KeybarKey(
    id: 'keyEnter',
    label: 'Enter',
    sequence: '\r',
    icon: Icons.keyboard_return,
  ),
  KeybarKey(
    id: 'keyPaste',
    label: 'Paste',
    sequence: '', // handled out-of-band
    icon: Icons.content_paste,
  ),
  // --- control sequences grouped LAST (owner-mandated, do not intersperse) ---
  KeybarKey(id: 'keyCtrlC', label: '^C', sequence: '\x03'),
  KeybarKey(id: 'keyCtrlZ', label: '^Z', sequence: '\x1a'),
  KeybarKey(id: 'keyCtrlB', label: '^B', sequence: '\x02'),
  KeybarKey(id: 'keyCtrlD', label: '^D', sequence: '\x04'),
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
          // #615: tighter vertical padding (was 4) to shrink the strip ~25%.
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
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
    // #615: ESC is the widest text key; render it at a smaller font so it fits
    // the shared normal button width instead of bulging the bar. Still plain
    // monochrome text (no Enter-ish glyph).
    final bool isEsc = keyData.id == 'keyEsc';
    // Monochrome icon (theme-tinted) when set, else the label glyph/text.
    // Never an emoji — see memory feedback_monochrome_icons_no_emoji.
    final Widget child = keyData.icon != null
        ? Icon(
            keyData.icon,
            size: kKeybarIconSize,
            color: theme.colorScheme.onSurface,
            semanticLabel: keyData.label,
          )
        : Text(
            keyData.label,
            style: TextStyle(
              fontSize: isEsc ? kKeybarEscFontSize : kKeybarLabelFontSize,
              fontFamily: 'monospace',
            ),
            overflow: TextOverflow.ellipsis,
          );
    return OutlinedButton(
      key: Key('keybar-btn-${keyData.id}'),
      onPressed: () => _onTap(context),
      style: OutlinedButton.styleFrom(
        // #615: tighter padding for the ~25% shrink. Still a touch-friendly
        // tap target via minimumSize below.
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // Every key shares the same min width so the bar stays even — ESC no
        // longer bulges (its smaller font fits this width).
        minimumSize: const Size(kKeybarButtonMinWidth, kKeybarButtonMinHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // #615: lighter outline — thinner, lower-opacity border so the bar
        // reads as a quiet strip rather than a grid of boxes.
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.4),
          width: 0.5,
        ),
        // Squarer look matching the PWA keybar — subtle rounding, not pill.
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
      ),
      child: child,
    );
  }
}
