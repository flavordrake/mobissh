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
// Visibility is PER-SESSION (#573): the terminal screen renders this widget
// only when the ACTIVE session's `sessionKeybarVisibleProvider` is true. The
// toggle lives in the session menu; this widget is just the renderer.

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
    this.isModifier = false,
  });

  final String id;
  final String label;
  final String sequence;

  /// When non-null, the button shows this monochrome icon instead of [label]
  /// text (e.g. Paste). [label] is still used as the accessibility tooltip.
  final IconData? icon;

  /// A sticky modifier key (the Ctrl key, #694) — tapping it ARMS the modifier
  /// rather than emitting [sequence]. Modifier keys carry no literal byte; the
  /// transform is applied to the NEXT key. See [CtrlModifier] / [ctrlTransform].
  final bool isModifier;
}

/// Transform a keybar [sequence] as if Ctrl were held (#694), mirroring the
/// PWA's `ctrlActive` mapping (`e.key.toLowerCase().charCodeAt(0) - 96`).
///
/// A single ASCII letter a–z / A–Z becomes its control byte via `& 0x1f`
/// (Ctrl+A = \x01 … Ctrl+Z = \x1a). Anything else — a multi-byte CSI escape
/// (arrows), an already-control byte (^C), an empty sequence (Paste), or a
/// symbol with no letter control meaning — passes through UNCHANGED. The caller
/// still clears the armed modifier afterward (one-shot sticky).
String ctrlTransform(String sequence) {
  if (sequence.length != 1) return sequence;
  final code = sequence.codeUnitAt(0);
  final isLetter =
      (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
  if (!isLetter) return sequence;
  return String.fromCharCode(code & 0x1f);
}

/// Sticky one-shot Ctrl modifier state (#694), mirroring the PWA's
/// `ctrlActive`. [arm] toggles the armed flag (a second tap CANCELS). [apply]
/// transforms the next key's sequence when armed and AUTO-CLEARS (one-shot).
///
/// Kept as a plain state holder (no widget dependency) so the arm/transform/
/// clear lifecycle is unit-testable — the keybar widget tap path hangs the
/// headless harness on Material ripple (see keybar_test.dart).
class CtrlModifier {
  bool _armed = false;

  bool get armed => _armed;

  /// Tap the Ctrl key: arm if disarmed, cancel if already armed.
  void arm() {
    _armed = !_armed;
  }

  /// Force the modifier off (e.g. when switching sessions).
  void clear() {
    _armed = false;
  }

  /// Apply Ctrl to [sequence] if armed, then auto-clear. Returns the bytes to
  /// actually send. When disarmed, returns [sequence] verbatim.
  String apply(String sequence) {
    if (!_armed) return sequence;
    _armed = false;
    return ctrlTransform(sequence);
  }
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
  // --- control group LAST (owner-mandated, do not intersperse) ---
  // #694: the sticky Ctrl MODIFIER leads the control group. Tapping it arms
  // Ctrl for the next keybar key (Ctrl+A..Z etc.), then auto-clears. It carries
  // no literal byte (isModifier). The fixed ^C/^Z/^B/^D quick-access combos
  // stay after it for one-tap common interrupts.
  KeybarKey(id: 'keyCtrl', label: 'Ctrl', sequence: '', isModifier: true),
  KeybarKey(id: 'keyCtrlC', label: '^C', sequence: '\x03'),
  KeybarKey(id: 'keyCtrlZ', label: '^Z', sequence: '\x1a'),
  KeybarKey(id: 'keyCtrlB', label: '^B', sequence: '\x02'),
  KeybarKey(id: 'keyCtrlD', label: '^D', sequence: '\x04'),
];

class Keybar extends ConsumerStatefulWidget {
  const Keybar({super.key, required this.activeEntry});

  final SessionEntry activeEntry;

  @override
  ConsumerState<Keybar> createState() => _KeybarState();
}

class _KeybarState extends ConsumerState<Keybar> {
  // #694: sticky one-shot Ctrl modifier, mirroring the PWA's `ctrlActive`.
  // Tapping the Ctrl key arms it; the next keybar key transforms to its control
  // byte, then it auto-clears.
  final CtrlModifier _ctrl = CtrlModifier();

  void _onKeyTap(KeybarKey k) {
    final terminal = widget.activeEntry.terminal;

    // The Ctrl modifier key itself: arm/cancel, no byte emitted.
    if (k.isModifier) {
      setState(_ctrl.arm);
      return;
    }

    // Paste pulls from the clipboard out-of-band. If Ctrl was armed, it has no
    // single-letter control meaning, so clear the modifier and paste literally.
    if (k.id == 'keyPaste') {
      final wasArmed = _ctrl.armed;
      if (wasArmed) setState(_ctrl.clear);
      _paste(terminal);
      return;
    }

    // Apply the (possibly armed) Ctrl transform and send. `apply` auto-clears
    // the one-shot modifier; rebuild so the armed highlight clears.
    final wasArmed = _ctrl.armed;
    final bytes = _ctrl.apply(k.sequence);
    if (bytes.isNotEmpty) terminal.textInput(bytes);
    if (wasArmed) setState(() {});
  }

  Future<void> _paste(Terminal terminal) async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      terminal.textInput(text);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    // The Ctrl key shows an accented/armed state while sticky.
                    armed: k.isModifier && _ctrl.armed,
                    onTap: () => _onKeyTap(k),
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
  const _KeybarButton({
    required this.keyData,
    required this.onTap,
    this.armed = false,
  });

  final KeybarKey keyData;
  final VoidCallback onTap;

  /// #694: when true (the armed Ctrl modifier), the button paints an accented
  /// highlight so it's clear Ctrl is sticky for the next key.
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // #615: ESC is the widest text key; render it at a smaller font so it fits
    // the shared normal button width instead of bulging the bar. Still plain
    // monochrome text (no Enter-ish glyph).
    final bool isEsc = keyData.id == 'keyEsc';
    // Monochrome icon (theme-tinted) when set, else the label glyph/text.
    // Never an emoji — see memory feedback_monochrome_icons_no_emoji.
    // #694: the armed Ctrl modifier paints accent-tinted text so the sticky
    // state reads clearly. Other keys use the normal onSurface tint.
    final Color fg = armed
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final Widget child = keyData.icon != null
        ? Icon(
            keyData.icon,
            size: kKeybarIconSize,
            color: fg,
            semanticLabel: keyData.label,
          )
        : Text(
            keyData.label,
            style: TextStyle(
              fontSize: isEsc ? kKeybarEscFontSize : kKeybarLabelFontSize,
              fontFamily: 'monospace',
              color: armed ? fg : null,
            ),
            overflow: TextOverflow.ellipsis,
          );
    return OutlinedButton(
      key: Key('keybar-btn-${keyData.id}'),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        // #694: armed Ctrl fills with the accent color so the sticky state is
        // unmistakable (mirrors the PWA's `.active` keybar styling).
        backgroundColor: armed ? theme.colorScheme.primary : null,
        // #615: tighter padding for the ~25% shrink. Still a touch-friendly
        // tap target via minimumSize below.
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // Every key shares the same min width so the bar stays even — ESC no
        // longer bulges (its smaller font fits this width).
        minimumSize: const Size(kKeybarButtonMinWidth, kKeybarButtonMinHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // #615: lighter outline — thinner, lower-opacity border so the bar
        // reads as a quiet strip rather than a grid of boxes. Armed Ctrl uses a
        // solid accent border to match its filled state.
        side: BorderSide(
          color: armed
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.4),
          width: armed ? 1.0 : 0.5,
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
