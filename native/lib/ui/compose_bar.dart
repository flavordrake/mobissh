// Compose bar — first-class IME / swipe / voice input surface (#599, #604).
//
// WHY THIS EXISTS: xterm.dart's internal text input hardcodes
// `autocorrect:false, enableSuggestions:false, enableIMEPersonalizedLearning:
// false`, telling Android/iOS to send DISCRETE keystrokes only — no composing
// stream. Swipe-typing and voice-to-text ARE a composing stream (the IME builds
// "hello world" with spaces, then commits), so the terminal drops them, spaces
// included. This editable has composing ENABLED, so swipe/voice/IME behave
// normally, then COMMIT (✓ text) / SUBMIT (⏎ text + Enter) to the session via
// the same `terminal.textInput` → onOutput → proxy.sendInput → PTY path as the
// keybar.
//
// #604: it's a FLOATING, DRAGGABLE panel overlaying the terminal (not docked in
// the Column), so it never pushes the terminal up / scrolls the cursor out of
// view. The owner composes long text here, so: vertical action-button stack
// (the field gets the width), draggable to reposition, and it floats above the
// soft keyboard. Drag the grip to move it; double-tap the grip to snap between
// the bottom and top thirds.
//
// #797: per-session compose history ring + ▲/▼ recall (PWA parity with
// src/modules/ime.ts `_commitHistory`) — sent commands are pushed to a
// per-session ring ([composeHistoryProvider]) so they survive the bar's
// close-on-send (#614), and ▲/▼ in the rail recall them into the buffer
// WITHOUT sending. Remaining PWA-parity extras (preview mode + auto-commit
// ring, sticky-Ctrl, password direct-mode, autocorrect diff) are backlogged on
// #599. Icons are monochrome theme-tinted Material icons — never emoji (memory:
// feedback_monochrome_icons_no_emoji).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/compose_history_providers.dart';
import '../state/lifecycle_providers.dart';
import '../util/terminal_copy_fixup.dart';

/// Bracketed-paste wrappers (#599): a multi-line commit is wrapped so the
/// remote TUI/shell treats it as a single paste rather than running each
/// embedded newline as Enter. Mirrors the PWA's `\x1b[200~...\x1b[201~`.
const String _bracketedPasteStart = '\x1b[200~';
const String _bracketedPasteEnd = '\x1b[201~';

/// A floating, draggable compose panel bound to the active session's
/// [terminal]. Nothing reaches the SSH session until commit/submit — text
/// accumulates locally first, so swipe/voice composition (a stream) lands
/// intact with spaces.
/// Where the compose panel anchors (#610, #798). [top]/[bottom] are the two
/// FIXED-margin dock anchors a quick FLICK snaps to — the anchor does NOT chase
/// the keyboard. [free] is the #798 hold-and-drag mode: the panel is pinned to an
/// exact top offset the finger chose, with NO snap.
enum ComposeDock { top, bottom, free }

class ComposeBar extends ConsumerStatefulWidget {
  const ComposeBar({
    super.key,
    required this.terminal,
    required this.sessionId,
    required this.onClose,
    this.bottomReserve = 0,
  });

  /// The active session's terminal. Committed text is sent via
  /// `terminal.textInput` (onOutput → proxy.sendInput → PTY), like the keybar.
  final Terminal terminal;

  /// The active session's id (#797). Keys the per-session compose history ring
  /// ([composeHistoryProvider]) so sent commands survive the bar's close-on-send
  /// (#614) and can be recalled with ▲/▼ — and never leak between sessions.
  final String sessionId;

  /// Hides the compose bar (clears `composeBarVisibleProvider`).
  final VoidCallback onClose;

  /// Height (logical px) of the chrome pinned to the bottom of the terminal
  /// screen (session bar + keybar, if visible). The bottom-docked panel sits
  /// ABOVE this so it never hides the session bar (#610 — owner: "hides bottom
  /// bar entirely"). Passed by terminal_screen, which knows the keybar state.
  final double bottomReserve;

  @override
  ConsumerState<ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends ConsumerState<ComposeBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Which edge the panel is docked to. Default TOP so it stays fully visible
  /// while the keyboard is up (the common swipe/voice compose case). A flick UP
  /// docks top, flick DOWN docks bottom; a hold-then-drag switches to
  /// [ComposeDock.free] and pins [_freeTop] exactly (#798).
  ComposeDock _dock = ComposeDock.top;

  /// #798: the exact top offset (logical px) the panel is pinned to while
  /// [_dock] == [ComposeDock.free]. Set by a hold-then-drag on the grip header;
  /// null in the docked modes. No snapping — the panel sits wherever the finger
  /// left it (clamped on-screen).
  double? _freeTop;

  /// #633: whether the compose field held focus when the app was last paused.
  /// On resume we re-`requestFocus()` only if this is true, so a background swap
  /// (lock screen, app switcher) doesn't lose the keyboard mid-compose. If the
  /// field wasn't focused at pause, resume leaves focus alone.
  bool _hadFocusAtPause = false;

  /// History browse cursor (#797) — ephemeral, mirrors the PWA's module-level
  /// `_historyIndex`/`_historyStash`. `-1` means "not browsing". `_historyStash`
  /// saves the live (unsent) compose text when browsing begins so ▼ past the
  /// newest entry can restore it instead of clobbering the draft. The durable
  /// list lives in [composeHistoryProvider] (per-session), keyed by
  /// `widget.sessionId`.
  int _historyIndex = -1;
  String _historyStash = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // Grab focus + raise the keyboard the instant the compose bar opens, so the
    // owner can go straight into voice/swipe typing (autofocus alone loses the
    // race against the terminal's focus management). Request after the first
    // frame, once the FocusNode is attached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// #633: re-focus the compose field across an app-swap. The OS drops soft-
  /// keyboard focus when the app is backgrounded; on resume we restore it (only
  /// if the field was focused at pause) so the owner returns to a live field
  /// with the keyboard up and the composed text intact. Mirrors the
  /// auto-focus-on-open pattern (dc6f803). We do NOT touch the keyboard/
  /// visualViewport handling (#610/#585) — just the FocusNode.
  void _onLifecycle(AppLifecycleState? prev, AppLifecycleState next) {
    if (next == AppLifecycleState.paused ||
        next == AppLifecycleState.inactive) {
      // Latch focus state at the moment we lose the foreground.
      if (next == AppLifecycleState.paused) {
        _hadFocusAtPause = _focusNode.hasFocus;
      }
    } else if (next == AppLifecycleState.resumed) {
      if (_hadFocusAtPause) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// Send staged text, optionally followed by [trailing] ('\r' for submit).
  /// Multi-line text is bracketed-paste wrapped so embedded newlines don't each
  /// fire Enter. #614 (owner reversal): BOTH commit (trailing=='') and submit
  /// (trailing=='\r') HIDE the panel afterward via [onClose], so the full
  /// terminal is readable once composing is done.
  void _send({required String trailing}) {
    final text = _controller.text;
    if (text.isEmpty && trailing.isEmpty) return;
    if (text.isNotEmpty) {
      final payload = text.contains('\n')
          ? '$_bracketedPasteStart$text$_bracketedPasteEnd'
          : text;
      widget.terminal.textInput(payload);
      // #797: record the sent command in the per-session history ring so it
      // can be recalled with ▲/▼ even after the panel closes. The notifier
      // dedups consecutive identical entries and caps the ring.
      ref
          .read(composeHistoryProvider.notifier)
          .push(widget.sessionId, text);
    }
    if (trailing.isNotEmpty) {
      widget.terminal.textInput(trailing);
    }
    _controller.clear();
    _resetHistoryCursor();
    // #614: hide the panel after sending (both commit and submit).
    widget.onClose();
  }

  /// #797: clear the browse cursor — called after a send or an explicit clear,
  /// so the next ▲ starts a fresh browse from the newest entry (mirrors the
  /// PWA resetting `_historyIndex` to -1 on record).
  void _resetHistoryCursor() {
    _historyIndex = -1;
    _historyStash = '';
  }

  /// #797: recall an entry from the per-session history ring into the compose
  /// buffer WITHOUT sending. Direction -1 (▲) walks toward older entries; +1
  /// (▼) toward newer, and past the newest restores the stashed draft. Mirrors
  /// the PWA `_navigateHistory` cycle exactly (src/modules/ime.ts):
  ///   - empty history → no-op
  ///   - not browsing (-1 index): ▲ stashes the live draft and lands on the
  ///     newest; ▼ is a no-op (already at the newest)
  ///   - past the newest → restore stash, leave browsing
  ///   - clamp at the oldest
  void _recall(int direction) {
    final history =
        ref.read(composeHistoryProvider.notifier).historyOf(widget.sessionId);
    if (history.isEmpty) return;
    String? next;
    if (_historyIndex == -1) {
      if (direction < 0) {
        _historyStash = _controller.text;
        _historyIndex = history.length - 1;
        next = history[_historyIndex];
      } else {
        return; // already at the newest — nothing newer to show
      }
    } else {
      _historyIndex += direction;
      if (_historyIndex >= history.length) {
        // Past the newest → restore the stashed draft, stop browsing.
        _historyIndex = -1;
        next = _historyStash;
      } else if (_historyIndex < 0) {
        // Clamp at the oldest.
        _historyIndex = 0;
        next = history[0];
      } else {
        next = history[_historyIndex];
      }
    }
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _focusNode.requestFocus();
    setState(() {});
  }

  void _clear() {
    _controller.clear();
    _resetHistoryCursor();
    _focusNode.requestFocus();
  }

  /// #798: a quick FLICK on the grip header snaps the panel to one of the two
  /// fixed dock anchors — up → TOP, down → BOTTOM — leaving [ComposeDock.free]
  /// behind. Mirrors the prior `onVerticalDragEnd` velocity test; extracted so
  /// it's unit-reasoned and the free-position path can coexist (the long-press
  /// recognizer wins the arena on a HOLD, so this only fires for fast drags).
  void _flickDock(double velocity) {
    if (velocity == 0) return;
    setState(() {
      _dock = velocity < 0 ? ComposeDock.top : ComposeDock.bottom;
      _freeTop = null;
    });
  }

  /// #798: a HOLD-then-drag on the grip header free-positions the panel to the
  /// exact top offset under the finger (no snap). [globalTop] is the desired
  /// panel-top in global/logical px; we clamp it so the grip stays reachable on
  /// screen. Switches [_dock] to [ComposeDock.free] and pins [_freeTop].
  void _freePositionTo(double globalTop, double screenHeight) {
    // Keep at least the grip header (24px) on screen at top and bottom.
    final maxTop = (screenHeight - 24).clamp(0.0, double.infinity);
    final clamped = globalTop.clamp(0.0, maxTop);
    setState(() {
      _dock = ComposeDock.free;
      _freeTop = clamped;
    });
  }

  /// #638 (was #634): copy the current compose text to the system clipboard
  /// (PWA parity — mirrors the IME compose Copy pill). Keeps focus in the field.
  void _copy() {
    final text = _controller.text;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    _focusNode.requestFocus();
  }

  /// #638: "Fix" pill — collapse terminal soft-wrap artifacts in the staged
  /// text into one clean line (PWA parity with `fixupTerminalCopy`). Used after
  /// pasting a long URL/command that the terminal hard-wrapped with newline +
  /// indent. Keeps the caret at the end and keeps focus.
  void _fix() {
    final cleaned = fixupTerminalCopy(_controller.text);
    if (cleaned == _controller.text) {
      _focusNode.requestFocus();
      return;
    }
    _controller.value = TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: cleaned.length),
    );
    _focusNode.requestFocus();
  }

  /// #638 (was #634): paste clipboard text into the compose field AT THE CURSOR
  /// (replacing any selection), then move the caret to the end of the inserted
  /// text.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text;
    if (pasted == null || pasted.isEmpty) return;
    if (!mounted) return;
    final value = _controller.value;
    final sel = value.selection;
    // Selection may be invalid (e.g. never focused); fall back to end-insert.
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final newText = value.text.replaceRange(start, end, pasted);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + pasted.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final size = media.size;

    // #633: re-focus the compose field across an app-swap (paused → resumed).
    // ref.listen so the side effect fires on the transition, not every build.
    ref.listen<AppLifecycleState>(lifecycleProvider, _onLifecycle);

    // Panel width: most of the screen, capped so it reads as a panel.
    final panelWidth = size.width - 24;
    // Tall enough for the top drag bar + the inline pill row (Fix/Copy/Paste,
    // #638) + the 6-button vertical action rail (#797: ▲/▼ history recall, then
    // close/clear/commit/submit) WITHOUT overflow — an overflowing Column under
    // Clip.antiAlias clips the bottom buttons so their taps don't land. Bumped
    // from 272 to 352 to seat the two extra history buttons.
    const panelHeight = 352.0;
    const margin = 12.0;
    final left = (size.width - panelWidth) / 2;

    // #610: anchor to a FIXED margin from the docked edge — do NOT chase the
    // keyboard inset. The old `height - keyboardInset - panelHeight` math put
    // the panel off-screen when the keyboard was hidden and let it cover the
    // session bar. Top dock = fixed top margin; bottom dock = above the session
    // bar (bottomReserve) by a fixed margin. The OS keeps the focused field
    // reachable; the panel's ANCHOR stays put regardless of keyboard state.
    final double? topPos;
    final double? bottomPos;
    switch (_dock) {
      case ComposeDock.top:
        topPos = margin;
        bottomPos = null;
      case ComposeDock.bottom:
        topPos = null;
        bottomPos = widget.bottomReserve + margin;
      case ComposeDock.free:
        // #798: hold-drag pinned the panel to an exact top offset — no snap.
        topPos = _freeTop ?? margin;
        bottomPos = null;
    }

    return Positioned(
      left: left,
      top: topPos,
      bottom: bottomPos,
      width: panelWidth,
      child: Material(
        key: const Key('compose-bar'),
        elevation: 12,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: panelHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag header (TOP edge, #634/#798): a slim full-width grab bar.
              // It carries an explicit GRIP affordance (a short pill grabber —
              // #798) so it reads as draggable, and owns all the move gestures so
              // they never land on the textarea (textareas intercept touch —
              // memory mobile-touch). A quick FLICK snaps to a dock anchor (up →
              // TOP, down → BOTTOM); a HOLD-then-drag free-positions exactly
              // (#798). Long-press wins the gesture arena on a hold, so the two
              // never conflict (mirrors ghostty_terminal_view.dart #688/#690).
              _DragHeader(
                key: const Key('compose-bar-drag'),
                onFlick: _flickDock,
                onHoldDrag: (globalTop) =>
                    _freePositionTo(globalTop, size.height),
                onToggleDock: () => setState(() {
                  _dock = _dock == ComposeDock.top
                      ? ComposeDock.bottom
                      : ComposeDock.top;
                  _freeTop = null;
                }),
              ),
              // #638/#798: inline TEXT-action pill row. Fix stays here as a wide
              // pill; Copy/Paste moved to small chips on the field's TOP BORDER
              // (#798) — see the Stack around the editable below.
              _PillRow(
                hasText: _controller.text.isNotEmpty,
                onFix: _fix,
              ),
              // Field + action rail share the remaining height.
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The editable — gets the width (slim vertical button rail).
                    // #798: small Copy/Paste chips are overlaid on the field's
                    // TOP BORDER via a Stack (clipBehavior:none so they straddle
                    // the outline). The field keeps an extra top inset so the
                    // chips don't cover the first line of text.
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            TextField(
                              key: const Key('compose-bar-input'),
                              controller: _controller,
                              focusNode: _focusNode,
                              autofocus: true,
                              // THE CRUX: composing/swipe/voice need these ENABLED.
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              autocorrect: true,
                              enableSuggestions: true,
                              enableIMEPersonalizedLearning: true,
                              expands: true,
                              minLines: null,
                              maxLines: null,
                              textAlignVertical: TextAlignVertical.top,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 15,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: 'Compose (swipe / voice / type)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                // #798: extra top inset clears the border chips.
                                contentPadding: const EdgeInsets.fromLTRB(
                                  10,
                                  16,
                                  10,
                                  8,
                                ),
                              ),
                            ),
                            // #798: Copy/Paste chips on the TOP BORDER. Centred
                            // on the outline (top:-2 ≈ the border line) and right-
                            // aligned so they don't fight the hint text.
                            Positioned(
                              top: -2,
                              right: 8,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _BorderChip(
                                    buttonKey: const Key('compose-bar-copy'),
                                    icon: Icons.copy_outlined,
                                    tooltip: 'Copy compose text',
                                    onPressed:
                                        _controller.text.isNotEmpty ? _copy : null,
                                  ),
                                  const SizedBox(width: 4),
                                  _BorderChip(
                                    buttonKey: const Key('compose-bar-paste'),
                                    icon: Icons.content_paste_outlined,
                                    tooltip: 'Paste at cursor',
                                    onPressed: _paste,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Vertical action rail (#604/#638/#797): WHOLE-VIEW actions
                    // only — ▲/▼ history recall, close, clear, commit, submit.
                    // Text actions (copy/paste/fix) live in the inline pill row.
                    _ActionRail(
                      hasText: _controller.text.isNotEmpty,
                      hasHistory: ref
                          .watch(composeHistoryProvider.select(
                            (m) => (m[widget.sessionId] ?? const []).isNotEmpty,
                          )),
                      onClose: widget.onClose,
                      onClear: _clear,
                      onHistoryUp: () => _recall(-1),
                      onHistoryDown: () => _recall(1),
                      onCommit: () => _send(trailing: ''),
                      onSubmit: () => _send(trailing: '\r'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline TEXT-action pill row (#638/#798). Mirrors the PWA's `.ime-paste-
/// overlay` chips (src/modules/ime.ts). #798 moved Copy/Paste to small chips on
/// the field's TOP BORDER, so this row now carries only the wide Fix pill (the
/// odd-one-out: it rewrites the staged text rather than touching the clipboard).
/// Monochrome, theme-tinted — no emoji (memory: feedback_monochrome_icons_no_emoji).
class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.hasText,
    required this.onFix,
  });

  final bool hasText;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('compose-bar-pills'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: [
          _Pill(
            buttonKey: const Key('compose-bar-fix'),
            icon: Icons.auto_fix_high_outlined,
            label: 'Fix',
            tooltip: 'Collapse terminal soft-wraps into one line',
            onPressed: hasText ? onFix : null,
          ),
        ],
      ),
    );
  }
}

/// A single chip-style text-action pill (#638). Tonal, compact, monochrome —
/// reads as a secondary affordance, not a primary button.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

/// #798: a small icon-only chip seated on the field's TOP BORDER (Copy/Paste).
/// The visual is compact (16px icon, tonal pill) but the tap target stays
/// finger-sized via a 44px [SizedBox] + an [IconButton] with no constraints
/// (its splash fills the box). Monochrome, theme-tinted — no emoji.
class _BorderChip extends StatelessWidget {
  const _BorderChip({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Full 44px hit area; the visible chip inside is small.
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          minimumSize: const Size(26, 26),
          fixedSize: const Size(26, 26),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
        icon: Icon(icon),
      ),
    );
  }
}

/// #798: the slim drag header at the top of the compose panel. It carries a
/// clear GRIP affordance (a short pill grabber) and owns the move gestures so
/// they never reach the textarea (textareas intercept touch — memory
/// mobile-touch). It uses a [RawGestureDetector] so a quick FLICK (vertical
/// drag) and a deliberate HOLD-then-drag (long press) can BOTH be recognised:
/// the long-press recognizer wins the arena once the finger dwells, mirroring
/// the swipe-vs-long-press split in ghostty_terminal_view.dart (#688/#690).
///   - Flick → [onFlick] with the end velocity (sign picks the dock anchor).
///   - Hold-then-drag → [onHoldDrag] with the live global panel-top offset.
///   - Double-tap → [onToggleDock] (legacy top↔bottom flip, #634).
class _DragHeader extends StatelessWidget {
  const _DragHeader({
    super.key,
    required this.onFlick,
    required this.onHoldDrag,
    required this.onToggleDock,
  });

  /// Quick flick ended — argument is the primary (vertical) velocity.
  final ValueChanged<double> onFlick;

  /// Hold-drag in progress — argument is the desired panel TOP in global px
  /// (finger Y minus a small grab offset so the grip stays under the finger).
  final ValueChanged<double> onHoldDrag;

  /// Double-tap toggles between the two dock anchors.
  final VoidCallback onToggleDock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        // Quick vertical drag → flick-to-dock. Loses the arena to the long
        // press when the finger holds still first (the hold-drag path).
        VerticalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              VerticalDragGestureRecognizer
            >(
              () => VerticalDragGestureRecognizer(),
              (r) => r.onEnd = (d) => onFlick(d.primaryVelocity ?? 0),
            ),
        // Hold (long press) then drag → free-position exactly, no snap.
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(),
              (r) => r
                ..onLongPressMoveUpdate = (d) =>
                    onHoldDrag(d.globalPosition.dy - 12),
            ),
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(),
              (r) => r.onDoubleTap = onToggleDock,
            ),
      },
      child: Container(
        height: 24,
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        // The grip: a short rounded pill bar that reads as "grab me". Monochrome,
        // theme-tinted (memory: feedback_monochrome_icons_no_emoji).
        child: Container(
          key: const Key('compose-bar-grip'),
          width: 36,
          height: 5,
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// Slim vertical button rail for the compose panel (#604/#638/#797). WHOLE-VIEW
/// actions only — history-up / history-down / close / clear / commit / submit.
/// Text actions live in the pill row. Stacking keeps the editable wide for long
/// composition. Monochrome theme-tinted icons (no emoji — memory:
/// feedback_monochrome_icons_no_emoji).
class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.hasText,
    required this.hasHistory,
    required this.onClose,
    required this.onClear,
    required this.onHistoryUp,
    required this.onHistoryDown,
    required this.onCommit,
    required this.onSubmit,
  });

  final bool hasText;

  /// #797: whether the active session has any recallable sent commands. Both
  /// ▲ and ▼ are disabled (dimmed) when false — PWA parity with the action
  /// bar's `disabled` toggle keyed on `_commitHistory.length > 0`.
  final bool hasHistory;
  final VoidCallback onClose;
  final VoidCallback onClear;
  final VoidCallback onHistoryUp;
  final VoidCallback onHistoryDown;
  final VoidCallback onCommit;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('compose-bar-rail'),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // #797: recall older (▲) / newer (▼) sent commands into the compose
          // buffer without sending. Disabled when the session has no history.
          IconButton(
            key: const Key('compose-bar-history-up'),
            tooltip: 'Recall older sent command',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: hasHistory ? onHistoryUp : null,
          ),
          IconButton(
            key: const Key('compose-bar-history-down'),
            tooltip: 'Recall newer sent command',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: hasHistory ? onHistoryDown : null,
          ),
          IconButton(
            key: const Key('compose-bar-close'),
            tooltip: 'Hide compose bar',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
          IconButton(
            key: const Key('compose-bar-clear'),
            tooltip: 'Clear',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.backspace_outlined),
            onPressed: hasText ? onClear : null,
          ),
          IconButton(
            key: const Key('compose-bar-commit'),
            tooltip: 'Send text (no Enter)',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            color: theme.colorScheme.primary,
            icon: const Icon(Icons.check),
            onPressed: hasText ? onCommit : null,
          ),
          IconButton(
            key: const Key('compose-bar-submit'),
            tooltip: 'Send text + Enter',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            color: theme.colorScheme.primary,
            icon: const Icon(Icons.keyboard_return),
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}
