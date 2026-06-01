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
import 'package:xterm/xterm.dart';

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

class ComposeBar extends StatefulWidget {
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
  State<ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<ComposeBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Which edge the panel is docked to. Default TOP so it stays fully visible
  /// while the keyboard is up (the common swipe/voice compose case). Double-tap
  /// the grip toggles top↔bottom.
  ComposeDock _dock = ComposeDock.top;

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
  /// fire Enter. Clears + keeps focus for the next swipe/voice phrase.
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
    _focusNode.requestFocus();
  }

  void _clear() {
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final size = media.size;

    // Panel width: most of the screen, capped so it reads as a panel.
    final panelWidth = size.width - 24;
    // Tall enough for the 4-button vertical action rail (close/clear/commit/
    // submit) WITHOUT overflow — an overflowing Column under Clip.antiAlias
    // clips the bottom buttons so their taps don't land.
    const panelHeight = 196.0;
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Dock grip (left edge): toggle the panel between the TOP and
              // BOTTOM margin so the user can keep the terminal cursor visible.
              // Double-tap or a vertical drag flips the dock; the anchor is
              // always a fixed margin (#610) — never free-floating off-screen.
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
                  width: 28,
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.drag_indicator,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // The editable — gets the width (buttons are a slim vertical rail).
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
              // Vertical action rail (#604): close / clear / commit / submit.
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
      ),
    );
  }
}

/// Slim vertical button rail for the compose panel (#604). Stacking the actions
/// keeps the editable wide for long composition. Monochrome theme-tinted icons.
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
