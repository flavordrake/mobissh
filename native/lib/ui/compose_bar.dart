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
// MVP slice. PWA-parity extras (preview mode + auto-commit ring, history ring,
// sticky-Ctrl, password direct-mode, autocorrect diff) are backlogged on #599.
// Icons are monochrome theme-tinted Material icons — never emoji (memory:
// feedback_monochrome_icons_no_emoji).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

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
/// Which edge the compose panel docks to (#610). The anchor is a FIXED margin
/// from that edge — it does NOT chase the keyboard. Dock TOP to compose with the
/// keyboard up (panel stays fully visible above it); dock BOTTOM to sit just
/// above the session bar.
enum ComposeDock { top, bottom }

class ComposeBar extends ConsumerStatefulWidget {
  const ComposeBar({
    super.key,
    required this.terminal,
    required this.onClose,
    this.bottomReserve = 0,
  });

  /// The active session's terminal. Committed text is sent via
  /// `terminal.textInput` (onOutput → proxy.sendInput → PTY), like the keybar.
  final Terminal terminal;

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
  /// while the keyboard is up (the common swipe/voice compose case). Double-tap
  /// the grip toggles top↔bottom.
  ComposeDock _dock = ComposeDock.top;

  /// #633: whether the compose field held focus when the app was last paused.
  /// On resume we re-`requestFocus()` only if this is true, so a background swap
  /// (lock screen, app switcher) doesn't lose the keyboard mid-compose. If the
  /// field wasn't focused at pause, resume leaves focus alone.
  bool _hadFocusAtPause = false;

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
    }
    if (trailing.isNotEmpty) {
      widget.terminal.textInput(trailing);
    }
    _controller.clear();
    // #614: hide the panel after sending (both commit and submit).
    widget.onClose();
  }

  void _clear() {
    _controller.clear();
    _focusNode.requestFocus();
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
    // #638) + the 4-button vertical action rail (close/clear/commit/submit)
    // WITHOUT overflow — an overflowing Column under Clip.antiAlias clips the
    // bottom buttons so their taps don't land.
    const panelHeight = 272.0;
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
    if (_dock == ComposeDock.top) {
      topPos = margin;
      bottomPos = null;
    } else {
      topPos = null;
      bottomPos = widget.bottomReserve + margin;
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
              // Dock grip (TOP edge, #634): a slim full-width bar so the text
              // field reclaims the left margin and reads wider. Toggle the panel
              // between the TOP and BOTTOM margin so the user can keep the
              // terminal cursor visible. Double-tap or a vertical drag flips the
              // dock; the anchor is always a fixed margin (#610) — never
              // free-floating off-screen.
              GestureDetector(
                key: const Key('compose-bar-drag'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < 0) setState(() => _dock = ComposeDock.top);
                  if (v > 0) setState(() => _dock = ComposeDock.bottom);
                },
                onDoubleTap: () => setState(() {
                  _dock = _dock == ComposeDock.top
                      ? ComposeDock.bottom
                      : ComposeDock.top;
                }),
                child: Container(
                  height: 24,
                  color: theme.colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.drag_handle,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // #638: inline TEXT-action pill row (Fix / Copy / Paste). These
              // are TEXT actions on the staged content — distinct from the
              // right rail's WHOLE-VIEW actions (close/clear/✓/⏎). Mirrors the
              // PWA's `.ime-paste-overlay` chips (src/modules/ime.ts), same
              // left→right order. Monochrome, theme-tinted (no emoji).
              _PillRow(
                hasText: _controller.text.isNotEmpty,
                onFix: _fix,
                onCopy: _copy,
                onPaste: _paste,
              ),
              // Field + action rail share the remaining height.
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The editable — gets the width (slim vertical button rail).
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                        child: TextField(
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
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Vertical action rail (#604/#638): WHOLE-VIEW actions
                    // only — close / clear / commit / submit. Text actions
                    // (copy/paste/fix) moved to the inline pill row above.
                    _ActionRail(
                      hasText: _controller.text.isNotEmpty,
                      onClose: widget.onClose,
                      onClear: _clear,
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

/// Inline TEXT-action pill row (#638). Mirrors the PWA's `.ime-paste-overlay`
/// chips (src/modules/ime.ts) — same left→right order: Fix, Copy, Paste. These
/// act on the staged TEXT (not the whole view), so they live as chips next to
/// the field rather than in the right rail (owner: "the copy paste and fix are
/// pills not cluttering up the right side for whole view actions"). Monochrome,
/// theme-tinted — no emoji (memory: feedback_monochrome_icons_no_emoji).
class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.hasText,
    required this.onFix,
    required this.onCopy,
    required this.onPaste,
  });

  final bool hasText;
  final VoidCallback onFix;
  final VoidCallback onCopy;
  final VoidCallback onPaste;

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
          const SizedBox(width: 6),
          _Pill(
            buttonKey: const Key('compose-bar-copy'),
            icon: Icons.copy_outlined,
            label: 'Copy',
            tooltip: 'Copy compose text',
            onPressed: hasText ? onCopy : null,
          ),
          const SizedBox(width: 6),
          _Pill(
            buttonKey: const Key('compose-bar-paste'),
            icon: Icons.content_paste_outlined,
            label: 'Paste',
            tooltip: 'Paste at cursor',
            onPressed: onPaste,
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

/// Slim vertical button rail for the compose panel (#604/#638). WHOLE-VIEW
/// actions only — close / clear / commit / submit. Text actions live in the
/// pill row. Stacking keeps the editable wide for long composition. Monochrome
/// theme-tinted icons.
class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.hasText,
    required this.onClose,
    required this.onClear,
    required this.onCommit,
    required this.onSubmit,
  });

  final bool hasText;
  final VoidCallback onClose;
  final VoidCallback onClear;
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
