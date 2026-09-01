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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/compose_sink_provider.dart';
import '../state/ctrl_modifier_provider.dart';
import '../state/input_mode_reset_provider.dart';
import '../state/sessions.dart';

/// Bottom-chrome sizing. These are the single source of truth for the button
/// geometry AND the vertical space the bar occupies — the latter
/// ([kKeybarReserve]) is consumed by the compose bar's bottom reserve in
/// terminal_screen.dart so a docked compose panel always clears the chrome.
///
/// #615 had shrunk the bar ~25% (minHeight 33, icon 14, label 12) for terminal
/// real estate, but owner device feedback (#696) found the labels too small and
/// too low-contrast to read over the terminal. #696 trades a little of that
/// vertical savings back for legibility: a clearly LARGER label font, with the
/// internal/text padding trimmed (owner-approved) so the taller text doesn't
/// grow the bar much, and the touch-target min-height restored to the 44px
/// floor. Colors go high-contrast (near-black key bg, bright label) in the
/// button style below.
///
/// Old values (pre-#615): minWidth 48, minHeight 44, icon 18, label 14.
///
/// #752: the bar was too TALL — it ate terminal real estate. The 44px height
/// floor forced ~26px of dead vertical space around an ~18px label. #752
/// collapses the VERTICAL spacing only (this floor, the scroll-view vertical
/// padding, and the per-key vertical padding) so each key HUGS its (unchanged)
/// label. The font (kKeybarLabelFontSize 14) and icon (kKeybarIconSize 18) are
/// untouched — keys stay just as readable. The horizontal min WIDTHs are
/// unchanged so keys stay comfortably tappable; only the height shrinks.
const double kKeybarButtonMinWidth = 44;
const double kKeybarButtonMinHeight = 32; // #752: was 44 (collapsed dead space)
const double kKeybarIconSize = 18;

/// #823: the arrow / navigation glyphs render LARGER than the standard
/// [kKeybarIconSize] so they read at a glance — the owner found the thin
/// chevrons hard to differentiate on-device. The size is deliberately capped at
/// the (unchanged) [kKeybarButtonMinHeight] so the bigger GLYPH never grows the
/// bar's height (#615/#752 trimmed it on purpose) — only the glyph inside the
/// existing key gets bigger and solid. Standard icons (Tab/Enter/Paste) stay at
/// [kKeybarIconSize]; only the arrow/nav keys opt into this larger size via
/// [KeybarKey.iconSize].
const double kKeybarNavIconSize = 24;

/// Single-character TEXT keys (`|`, `/`, `-` and any other 1-glyph label) are
/// NARROWER than multi-char keys so they don't waste width (#703 owner device
/// feedback). Multi-char text keys (Esc, Tab label, Home, PgUp…) keep the full
/// [kKeybarButtonMinWidth] so they never clip. Icon keys also keep the full
/// width. The tap-target HEIGHT is unchanged ([kKeybarButtonMinHeight]) — only
/// horizontal width shrinks.
const double kKeybarSingleCharMinWidth = 30;

/// #703: ALL keybar TEXT labels render at ONE uniform size — the smaller ESC
/// size. The owner asked for a single, smaller text size across the bar (icons
/// stay legible at [kKeybarIconSize]). [kKeybarEscFontSize] is the single
/// source of truth for that uniform text size.
///
/// #615 had shrunk the bar; #696 bumped labels back up to ~17 for legibility
/// but kept ESC a notch smaller (14) so it shared the normal width. #703
/// collapses the two: every text key now uses the ESC size, so the constant is
/// reused for every label below.
const double kKeybarLabelFontSize = 14;

/// The uniform keybar text size (#703). ESC is no longer special-cased — this
/// is simply the one text size used for ALL text labels. Kept as a distinct
/// (equal) constant so call sites and tests stay readable.
const double kKeybarEscFontSize = 14;

/// Vertical space (logical px) the keybar occupies, used as the compose-bar
/// bottom reserve. Button height (32) + the 2px top/bottom scroll-view padding,
/// rounded up for a small safety margin so a docked compose panel clears the
/// chrome. #752: tracks the collapsed bar height (was 56 for the old 44px bar).
const double kKeybarReserve = 40;

/// High-contrast keybar palette (#696). Owner device feedback: the old
/// dark-blue (theme `surfaceContainerHigh`) bar + dim `onSurface` labels were
/// too low-contrast to read over the terminal. The owner's example was BLACK
/// keys instead of dark-blue. We back the bar with near-black, fill each key a
/// touch above it so the keys read as distinct faces, and paint the labels
/// near-white. Monochrome (no color/emoji — project rule); the theme accent is
/// reserved for the armed-Ctrl state so it still pops against the dark keys.
const Color kKeybarBarColor = Color(0xFF000000); // bar backing — black
const Color kKeybarKeyColor = Color(0xFF1A1A1A); // key face — near-black
const Color kKeybarLabelColor = Color(0xFFF2F2F2); // label — near-white

/// One key on the bar. Renders [label] text, OR [icon] (a monochrome
/// theme-tinted Material icon) when set — never an emoji.
class KeybarKey {
  const KeybarKey({
    required this.id,
    required this.label,
    required this.sequence,
    this.icon,
    this.iconSize = kKeybarIconSize,
    this.isModifier = false,
    this.isCharacter = false,
  });

  final String id;
  final String label;
  final String sequence;

  /// When non-null, the button shows this monochrome icon instead of [label]
  /// text (e.g. Paste). [label] is still used as the accessibility tooltip.
  final IconData? icon;

  /// Size of [icon] when shown. Defaults to the standard [kKeybarIconSize]; the
  /// arrow / navigation keys opt into the larger [kKeybarNavIconSize] (#823) so
  /// their solid glyphs read at a glance without growing the bar height.
  final double iconSize;

  /// A sticky modifier key (the Ctrl key, #694) — tapping it ARMS the modifier
  /// rather than emitting [sequence]. Modifier keys carry no literal byte; the
  /// transform is applied to the NEXT key. See [CtrlModifier] / [ctrlTransform].
  final bool isModifier;

  /// This key types a PRINTABLE character (#1131). While the compose bar (IME
  /// preview) is open, these insert into the compose buffer instead of going to
  /// the terminal; everything else — nav keys, Esc, ^C/^Z/^B/^D, Tab — keeps
  /// its terminal-bound behavior.
  ///
  /// Set EXPLICITLY, never inferred from [sequence]: Esc and the control keys
  /// carry sequences too, and Tab's `\t` is a shell-completion trigger rather
  /// than text the owner wants staged in the buffer.
  final bool isCharacter;
}

/// Where a keybar key's bytes land (#1131).
enum KeybarRoute {
  /// Straight to the session terminal — the historical behaviour.
  terminal,

  /// Inserted at the caret in the compose bar's buffer (IME preview).
  composeInsert,

  /// Sends the staged compose text + Enter, like the bar's ⏎ action.
  composeSubmit,
}

/// Decide where [key] goes. PURE so the routing contract is unit-testable —
/// the keybar widget's tap path hangs the headless harness on Material ripple
/// (same reason [ctrlTransform] is a free function; see keybar_test.dart).
///
/// Rules (owner-specified, #1131):
/// - Compose bar closed ⇒ everything goes to the terminal (unchanged).
/// - An ARMED Ctrl always means "control byte to the terminal" — the owner
///   armed it deliberately, so it outranks compose routing.
/// - Character keys ([KeybarKey.isCharacter]) insert into the buffer.
/// - Enter submits the buffer ONLY when it holds text; with an empty buffer it
///   stays a bare `\r` so a plain Enter never changes meaning.
/// - Everything else — nav keys, Esc, ^C/^Z/^B/^D, Tab — stays terminal-bound.
KeybarRoute resolveKeybarRoute({
  required KeybarKey key,
  required bool composeOpen,
  required bool composeHasText,
  required bool ctrlArmed,
}) {
  if (!composeOpen || ctrlArmed) return KeybarRoute.terminal;
  if (key.isCharacter) return KeybarRoute.composeInsert;
  if (key.id == 'keyEnter' && composeHasText) return KeybarRoute.composeSubmit;
  return KeybarRoute.terminal;
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
  // #703: the sticky Ctrl MODIFIER now leads the bar, immediately after Esc
  // (owner device feedback overriding #694's control-group placement for the
  // modifier specifically). Tapping it arms Ctrl for the next keybar key
  // (Ctrl+A..Z etc.), then auto-clears. It carries no literal byte
  // (isModifier). The FIXED ^C/^Z/^B/^D quick combos stay grouped at the END.
  KeybarKey(id: 'keyCtrl', label: 'Ctrl', sequence: '', isModifier: true),
  KeybarKey(id: 'keyTab', label: '↹', sequence: '\t'),
  KeybarKey(id: 'keySlash', label: '/', sequence: '/', isCharacter: true),
  KeybarKey(id: 'keyDash', label: '-', sequence: '-', isCharacter: true),
  KeybarKey(id: 'keyPipe', label: '|', sequence: '|', isCharacter: true),
  // #823: the four arrows use SOLID/FILLED directional glyphs (Icons.arrow_*)
  // rather than the thin `keyboard_arrow_*` chevrons the owner found hard to
  // read and differentiate on-device. They render at the larger
  // [kKeybarNavIconSize] so they read at a glance without growing the bar.
  KeybarKey(
    id: 'keyLeft',
    label: 'Left',
    sequence: '\x1b[D',
    icon: Icons.arrow_back,
    iconSize: kKeybarNavIconSize,
  ),
  KeybarKey(
    id: 'keyUp',
    label: 'Up',
    sequence: '\x1b[A',
    icon: Icons.arrow_upward,
    iconSize: kKeybarNavIconSize,
  ),
  KeybarKey(
    id: 'keyDown',
    label: 'Down',
    sequence: '\x1b[B',
    icon: Icons.arrow_downward,
    iconSize: kKeybarNavIconSize,
  ),
  KeybarKey(
    id: 'keyRight',
    label: 'Right',
    sequence: '\x1b[C',
    icon: Icons.arrow_forward,
    iconSize: kKeybarNavIconSize,
  ),
  // #823: the page-navigation keys also become SOLID, mutually-distinct glyphs
  // (single bar-anchored first/last_page for Home/End, double-chevron for the
  // Page keys) at the larger nav size — they were ambiguous text labels before.
  // The `label` is still the accessibility tooltip; routing uses `sequence`.
  KeybarKey(
    id: 'keyHome',
    label: 'Home',
    sequence: '\x1b[H',
    icon: Icons.first_page,
    iconSize: kKeybarNavIconSize,
  ),
  KeybarKey(
    id: 'keyEnd',
    label: 'End',
    sequence: '\x1b[F',
    icon: Icons.last_page,
    iconSize: kKeybarNavIconSize,
  ),
  KeybarKey(
    id: 'keyPgUp',
    label: 'PgUp',
    sequence: '\x1b[5~',
    icon: Icons.keyboard_double_arrow_up,
    iconSize: kKeybarNavIconSize,
  ),
  KeybarKey(
    id: 'keyPgDn',
    label: 'PgDn',
    sequence: '\x1b[6~',
    icon: Icons.keyboard_double_arrow_down,
    iconSize: kKeybarNavIconSize,
  ),
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
  // One-shot "unstick the terminal" key: clears stuck input modes (mouse
  // reporting) LOCALLY so taps stop echoing SGR garbage at the prompt. Handled
  // out-of-band via inputModeResetProvider — emits no byte to the remote.
  KeybarKey(
    id: 'keyResetInput',
    label: 'Reset input',
    sequence: '', // handled out-of-band
    icon: Icons.restart_alt,
  ),
  // --- fixed control combos grouped LAST (owner-mandated, do not intersperse) ---
  // The one-tap ^C/^Z/^B/^D interrupts stay grouped at the END. The sticky Ctrl
  // MODIFIER moved to the FRONT (right after Esc) per #703 — only the modifier
  // moved; these fixed combos keep their tail grouping.
  KeybarKey(id: 'keyCtrlC', label: '^C', sequence: '\x03'),
  KeybarKey(id: 'keyCtrlZ', label: '^Z', sequence: '\x1a'),
  KeybarKey(id: 'keyCtrlB', label: '^B', sequence: '\x02'),
  KeybarKey(id: 'keyCtrlD', label: '^D', sequence: '\x04'),
];

/// Keys that AUTO-REPEAT on press-and-hold (#732). Cursor / navigation keys
/// only — holding one repeats the SAME keystroke until release, so arrowing
/// through shell history / moving the cursor / scrolling a TUI doesn't need
/// many taps. Keyed on the key id so the set is EXPLICIT and trivial to extend.
///
/// Deliberately EXCLUDED: modifier / one-shot keys (Esc, the sticky Ctrl,
/// Tab), symbol keys (/ - |), the fixed control combos (^C/^Z/^B/^D), Enter
/// (one line at a time), and Paste (out-of-band). A hold on those does nothing
/// extra — a single tap still sends exactly once.
const Set<String> kRepeatEligibleKeyIds = {
  'keyLeft',
  'keyUp',
  'keyDown',
  'keyRight',
  'keyHome',
  'keyEnd',
  'keyPgUp',
  'keyPgDn',
};

/// Whether the keybar key with [id] auto-repeats on press-and-hold (#732).
bool isRepeatEligibleKeyId(String id) => kRepeatEligibleKeyIds.contains(id);

/// Default press-and-hold timing (#732), matching the standard terminal
/// key-repeat feel: a brief initial delay before repeating kicks in (so a quick
/// tap never repeats), then a steady, fast cadence until the finger lifts.
const Duration kKeyRepeatInitialDelay = Duration(milliseconds: 400);
const Duration kKeyRepeatInterval = Duration(milliseconds: 60);

/// Drives the press-and-hold auto-repeat for a single keybar key (#732).
///
/// Kept as a plain, widget-free state holder (like [CtrlModifier]) so the timer
/// lifecycle is unit-testable with `fakeAsync` — the keybar widget tap path
/// hangs the headless harness on Material ripple animations (see
/// keybar_test.dart).
///
/// Lifecycle: [start] schedules an initial-delay [Timer]; when it fires, the
/// first [onTick] runs and a [Timer.periodic] takes over at [interval], firing
/// [onTick] each tick. [stop] cancels BOTH timers (idempotent) — call it on
/// pointer up / cancel / dispose. Because the first tick only fires AFTER
/// [initialDelay], a quick tap (released before the delay) produces ZERO ticks,
/// so the tap's single send is never doubled.
///
/// The controller is intentionally haptic-agnostic: it fires only [onTick]; the
/// widget's tick callback does the byte-send AND the per-tick haptic. That
/// keeps the timer logic cleanly unit-testable (the haptic is device-validated).
class KeyRepeatController {
  KeyRepeatController({
    this.initialDelay = kKeyRepeatInitialDelay,
    this.interval = kKeyRepeatInterval,
  });

  final Duration initialDelay;
  final Duration interval;

  Timer? _initialTimer;
  Timer? _repeatTimer;

  /// True once the hold has begun (initial-delay or repeat timer is live).
  bool get isRunning => _initialTimer != null || _repeatTimer != null;

  /// Begin the hold: after [initialDelay], fire [onTick] once and start the
  /// periodic repeat. Restarting while already running cancels the prior
  /// schedule first (no overlapping cadence, no leaked timer).
  void start(void Function() onTick) {
    stop();
    _initialTimer = Timer(initialDelay, () {
      _initialTimer = null;
      onTick();
      _repeatTimer = Timer.periodic(interval, (_) => onTick());
    });
  }

  /// Cancel the hold immediately. Safe to call when nothing is running and safe
  /// to call repeatedly (idempotent).
  void stop() {
    _initialTimer?.cancel();
    _initialTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }
}

class Keybar extends ConsumerStatefulWidget {
  const Keybar({super.key, required this.activeEntry});

  final SessionEntry activeEntry;

  @override
  ConsumerState<Keybar> createState() => _KeybarState();
}

class _KeybarState extends ConsumerState<Keybar> {
  // #694 + #728: the sticky one-shot Ctrl modifier now lives in the SHARED
  // [ctrlModifierProvider] (state/ctrl_modifier_provider.dart) rather than a
  // widget-local `CtrlModifier`, so the terminal soft-keyboard input path
  // (flterm `controller.onOutput`) can read + clear the SAME armed state. There
  // are no letter keys on the bar, so Ctrl+R is typed on the keyboard — #728
  // makes that path see this arm. The keybar drives the provider (toggle on the
  // Ctrl key, consume on the next keybar key) and reads it for the armed
  // highlight; the per-key byte transform still uses the pure [ctrlTransform],
  // exactly as #694's `CtrlModifier.apply` did.

  void _onKeyTap(KeybarKey k) {
    final terminal = widget.activeEntry.terminal;
    final ctrl = ref.read(ctrlModifierProvider.notifier);

    // Every keybar tap clicks (owner 2026-09-01: `-` gave no haptic). Fired
    // BEFORE routing so it doesn't depend on where the bytes land — terminal,
    // compose buffer (#1131), or nowhere (Ctrl arm, Reset). Same
    // `selectionClick` as the #732 repeat ticks, the lightest device-validated
    // one; the OutlinedButton's own tap feedback is sound-only on Android.
    HapticFeedback.selectionClick();

    // The Ctrl modifier key itself: arm/cancel, no byte emitted. `toggle` mirrors
    // #694 (a second Ctrl tap cancels). Reading the provider drives the rebuild.
    if (k.isModifier) {
      ctrl.toggle();
      return;
    }

    // Paste pulls from the clipboard out-of-band. If Ctrl was armed, it has no
    // single-letter control meaning, so clear the modifier and paste literally.
    if (k.id == 'keyPaste') {
      ctrl.disarm();
      _paste(terminal);
      return;
    }

    // Reset input modes: a LOCAL one-shot to clear stuck mouse reporting so taps
    // stop echoing SGR codes. Signals the active session's terminal view via
    // inputModeResetProvider — no byte reaches the remote. Clear any armed Ctrl.
    if (k.id == 'keyResetInput') {
      ctrl.disarm();
      ref
          .read(inputModeResetProvider.notifier)
          .requestReset(widget.activeEntry.id);
      return;
    }

    // #1131: while the IME preview is up, CHARACTER keys belong in the compose
    // buffer — sending them to the terminal split the owner's input across two
    // destinations mid-compose. Nav/control keys stay terminal-bound.
    final sink = ref.read(composeSinkProvider);
    switch (resolveKeybarRoute(
      key: k,
      composeOpen: sink != null,
      composeHasText: sink?.hasText() ?? false,
      ctrlArmed: ref.read(ctrlModifierProvider),
    )) {
      case KeybarRoute.composeInsert:
        sink!.insertText(k.sequence);
        return;
      case KeybarRoute.composeSubmit:
        sink!.submit();
        return;
      case KeybarRoute.terminal:
        break;
    }

    // Apply the (possibly armed) one-shot Ctrl transform and send. `consume`
    // reads + clears the shared modifier (so the keybar highlight clears and the
    // terminal path won't also see it); the byte transform mirrors #694.
    final wasArmed = ctrl.consume();
    final bytes = wasArmed ? ctrlTransform(k.sequence) : k.sequence;
    if (bytes.isNotEmpty) terminal.textInput(bytes);
  }

  /// One auto-repeat tick for a held nav key (#732). Reuses the SAME byte-send
  /// the tap path uses ([_onKeyTap] for a non-modifier, non-paste key): apply
  /// the one-shot Ctrl transform if armed, then forward the bytes. The first
  /// tick consumes any armed Ctrl exactly as a tap would (one-shot, mirrors
  /// #694); subsequent ticks send the plain CSI sequence — Ctrl never re-arms
  /// itself, so a held arrow keeps sending the arrow. A minuscule
  /// `HapticFeedback.selectionClick()` accompanies each tick (owner: the
  /// lightest, device-validated). Only eligible keys ever reach here.
  void _onRepeatTick(KeybarKey k) {
    final terminal = widget.activeEntry.terminal;
    final ctrl = ref.read(ctrlModifierProvider.notifier);
    // #1131: same compose routing as the tap path — only nav keys are
    // repeat-eligible today, but the two paths must never disagree about where
    // a key's bytes land (#732 shares the send for exactly this reason).
    final sink = ref.read(composeSinkProvider);
    if (resolveKeybarRoute(
          key: k,
          composeOpen: sink != null,
          composeHasText: sink?.hasText() ?? false,
          ctrlArmed: ref.read(ctrlModifierProvider),
        ) ==
        KeybarRoute.composeInsert) {
      sink!.insertText(k.sequence);
      HapticFeedback.selectionClick();
      return;
    }
    final wasArmed = ctrl.consume();
    final bytes = wasArmed ? ctrlTransform(k.sequence) : k.sequence;
    if (bytes.isNotEmpty) terminal.textInput(bytes);
    HapticFeedback.selectionClick();
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
    // #728: the armed-Ctrl highlight reads the SHARED provider so it stays in
    // sync whether the modifier was consumed by a keybar key OR by a keyboard
    // keystroke through the terminal input path.
    final ctrlArmed = ref.watch(ctrlModifierProvider);
    return Material(
      key: const Key('keybar'),
      // #696: high-contrast strip. The bar backs the keys with near-black so the
      // brighter key faces read clearly over the terminal, instead of the old
      // dark-blue surfaceContainerHigh tint that washed the labels out.
      color: kKeybarBarColor,
      child: SafeArea(
        top: false,
        // ONE LINE that scrolls horizontally (owner 2026-06-01). 16 keys can't
        // fit a phone width at a touch-friendly size, so the row scrolls rather
        // than stacking into a second line or shrinking buttons below the tap
        // target. Each button has a comfortable min width.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // #615: tighter vertical padding (was 4) to shrink the strip ~25%.
          // #752: trimmed again (3 → 2) to collapse the bar's outer margin so
          // the keys hug the chrome edges; horizontal padding is unchanged.
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in kDefaultKeybarKeys)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _KeybarButton(
                    keyData: k,
                    // The Ctrl key shows an accented/armed state while sticky.
                    armed: k.isModifier && ctrlArmed,
                    onTap: () => _onKeyTap(k),
                    // #732: press-and-hold auto-repeat for cursor/nav keys only.
                    // null for non-eligible keys → no repeat wiring at all (a
                    // hold does nothing extra, a tap still sends once).
                    onRepeat: isRepeatEligibleKeyId(k.id)
                        ? () => _onRepeatTick(k)
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeybarButton extends StatefulWidget {
  const _KeybarButton({
    required this.keyData,
    required this.onTap,
    this.armed = false,
    this.onRepeat,
  });

  final KeybarKey keyData;
  final VoidCallback onTap;

  /// #694: when true (the armed Ctrl modifier), the button paints an accented
  /// highlight so it's clear Ctrl is sticky for the next key.
  final bool armed;

  /// #732: press-and-hold auto-repeat handler. Non-null ONLY for repeat-eligible
  /// (cursor/nav) keys — a hold then fires this once per repeat tick after the
  /// initial delay. Null for every other key, which therefore never repeats.
  final VoidCallback? onRepeat;

  @override
  State<_KeybarButton> createState() => _KeybarButtonState();
}

class _KeybarButtonState extends State<_KeybarButton> {
  // #732: each eligible button owns its own auto-repeat controller so a held
  // pointer repeats the keystroke. Cancelled on pointer up / cancel / dispose
  // so a lifted finger stops immediately and an unmounted widget leaks no timer.
  final KeyRepeatController _repeat = KeyRepeatController();

  @override
  void dispose() {
    _repeat.stop();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent _) {
    final onRepeat = widget.onRepeat;
    if (onRepeat == null) return; // non-eligible key — never repeats.
    _repeat.start(onRepeat);
  }

  void _stopRepeat() => _repeat.stop();

  @override
  Widget build(BuildContext context) {
    final keyData = widget.keyData;
    final armed = widget.armed;
    final onTap = widget.onTap;
    final theme = Theme.of(context);
    // #703: a single-character TEXT key (`|`, `/`, `-`, …) gets a narrower min
    // width so it doesn't waste horizontal space. Icon keys and multi-char text
    // keys keep the full width so they never clip. Height is unchanged.
    final bool isSingleChar = keyData.icon == null && keyData.label.length == 1;
    final double minWidth = isSingleChar
        ? kKeybarSingleCharMinWidth
        : kKeybarButtonMinWidth;
    // Monochrome icon (theme-tinted) when set, else the label glyph/text.
    // Never an emoji — see memory feedback_monochrome_icons_no_emoji.
    // #694: the armed Ctrl modifier paints accent-tinted text so the sticky
    // state reads clearly. #696: other keys use a bright near-white label for
    // high contrast against the near-black key face (the old dim `onSurface`
    // tint was unreadable over the terminal).
    final Color fg = armed ? theme.colorScheme.onPrimary : kKeybarLabelColor;
    final Widget child = keyData.icon != null
        ? Icon(
            keyData.icon,
            // #823: arrow/nav keys opt into the larger nav size; other icons
            // keep the standard size. Capped at the bar height so the bigger
            // glyph never grows the bar.
            size: keyData.iconSize,
            color: fg,
            semanticLabel: keyData.label,
          )
        : Text(
            keyData.label,
            style: TextStyle(
              // #703: ONE uniform text size for every label (the smaller ESC
              // size). Icons stay at kKeybarIconSize so they remain legible.
              fontSize: kKeybarLabelFontSize,
              fontFamily: 'monospace',
              // #696: always the high-contrast label color (armed = onPrimary,
              // else the bright near-white) so it reads over the dark key face.
              color: fg,
            ),
            overflow: TextOverflow.ellipsis,
          );
    final button = OutlinedButton(
      key: Key('keybar-btn-${keyData.id}'),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        // #694: armed Ctrl fills with the accent color so the sticky state is
        // unmistakable (mirrors the PWA's `.active` keybar styling). #696:
        // unarmed keys fill near-black so each key reads as a distinct face
        // against the black bar and the bright label pops.
        backgroundColor: armed ? theme.colorScheme.primary : kKeybarKeyColor,
        foregroundColor: fg,
        // #696: trim the internal padding so the label fits without growing the
        // bar height. The comfortable tap target is preserved via minimumSize
        // below. #703: single-char keys also trim horizontal padding so they
        // read as tight, narrow keys. #752: collapse the per-key VERTICAL
        // padding (2 → 1) so the key hugs its (unchanged) label glyph; the
        // horizontal padding is untouched so keys stay tappable.
        padding: EdgeInsets.symmetric(
          horizontal: isSingleChar ? 2 : 6,
          vertical: 1,
        ),
        // #703: single-char text keys use a narrower min width so they don't
        // waste space; multi-char and icon keys keep the full width. Height is
        // the same comfortable tap target for every key.
        minimumSize: Size(minWidth, kKeybarButtonMinHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // #696: a subtle light hairline separates each near-black key face from
        // the black bar so the keys read as distinct buttons (the #615 dim
        // outline disappeared against black). Armed Ctrl keeps its solid accent
        // border to match its filled state.
        side: BorderSide(
          color: armed
              ? theme.colorScheme.primary
              : kKeybarLabelColor.withValues(alpha: 0.22),
          width: armed ? 1.0 : 0.5,
        ),
        // Squarer look matching the PWA keybar — subtle rounding, not pill.
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
      ),
      child: child,
    );

    // #732: a pointer-level Listener drives press-and-hold auto-repeat WITHOUT
    // interfering with the button's own tap (onPressed still fires exactly once
    // for a quick tap). For non-eligible keys onRepeat is null and the pointer
    // handlers are no-ops, so those keys behave exactly as before. Pointer up
    // AND cancel both stop the repeat so a lifted/slid-off finger halts it
    // immediately. behavior: deferToChild keeps the button hit-testable.
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: (_) => _stopRepeat(),
      onPointerCancel: (_) => _stopRepeat(),
      behavior: HitTestBehavior.deferToChild,
      child: button,
    );
  }
}
