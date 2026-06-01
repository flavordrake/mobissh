// Compose bar — first-class IME / swipe / voice input surface (#599).
//
// WHY THIS EXISTS: xterm.dart's internal text input hardcodes
// `autocorrect:false, enableSuggestions:false, enableIMEPersonalizedLearning:
// false`, which tells Android/iOS to send DISCRETE keystrokes only — no
// composing stream. Swipe-typing and voice-to-text ARE a composing stream (the
// IME builds "hello world" with spaces, then commits), so they're silently
// dropped by the terminal directly — including the spaces. This is the owner's
// pain ("swipe type and spaces appear correctly", and voice is where the volume
// is).
//
// The fix (PWA `src/modules/ime.ts` model, ported): a real Flutter TextField
// with composing/autocorrect/suggestions ENABLED. You swipe / dictate / type
// into it (spaces land because it's a normal editable), then COMMIT (✓ sends
// the text) or SUBMIT (⏎ sends text + Enter) to the active session — the same
// `terminal.textInput` → onOutput → proxy.sendInput → PTY path the keybar uses.
//
// This is the MVP slice: visible editable + commit/submit/clear + bracketed
// paste for multi-line. PWA-parity extras (preview mode + auto-commit ring,
// history ring, sticky-Ctrl, password direct-mode, dock top/bottom, autocorrect
// diff) are backlogged on #599.
//
// Icons are monochrome theme-tinted Material icons — never emoji (memory:
// feedback_monochrome_icons_no_emoji).

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Bracketed-paste wrappers (#599): a multi-line commit is wrapped so the
/// remote TUI/shell treats it as a single paste rather than running each
/// embedded newline as Enter. Mirrors the PWA's `\x1b[200~...\x1b[201~`.
const String _bracketedPasteStart = '\x1b[200~';
const String _bracketedPasteEnd = '\x1b[201~';

/// A docked compose surface bound to the active session's [terminal]. Renders
/// nothing to the SSH session until the user commits/submits — text accumulates
/// locally first, so swipe/voice composition (which arrives as a stream) lands
/// intact with spaces.
class ComposeBar extends StatefulWidget {
  const ComposeBar({super.key, required this.terminal});

  /// The active session's terminal. Committed text is sent via
  /// `terminal.textInput`, which routes through the standard keystroke pipe
  /// (onOutput → proxy.sendInput → PTY) — identical to the keybar.
  final Terminal terminal;

  @override
  State<ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<ComposeBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Rebuild so the commit/submit buttons enable/disable with content.
    setState(() {});
  }

  /// Send the staged text, optionally followed by [trailing] (e.g. '\r' for
  /// submit). Multi-line text is bracketed-paste wrapped so embedded newlines
  /// don't each fire Enter on the remote. Clears the field and keeps focus so
  /// the next swipe/voice phrase can follow immediately.
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
    // Keep the keyboard up / surface ready for the next phrase.
    _focusNode.requestFocus();
  }

  void _clear() {
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = _controller.text.isNotEmpty;
    return Material(
      key: const Key('compose-bar'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('compose-bar-input'),
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  // THE CRUX: composing/swipe/voice need these ENABLED — the
                  // opposite of xterm's internal config. multiline keyboard so
                  // the action key is a newline (submit is the ⏎ button), and
                  // so swipe/voice produce a composing stream with spaces.
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  autocorrect: true,
                  enableSuggestions: true,
                  enableIMEPersonalizedLearning: true,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Compose (swipe / voice / type) → ✓ send',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('compose-bar-clear'),
                tooltip: 'Clear',
                onPressed: hasText ? _clear : null,
                icon: const Icon(Icons.backspace_outlined, size: 20),
              ),
              IconButton(
                key: const Key('compose-bar-commit'),
                tooltip: 'Send text (no Enter)',
                color: theme.colorScheme.primary,
                onPressed: hasText ? () => _send(trailing: '') : null,
                icon: const Icon(Icons.check, size: 22),
              ),
              IconButton(
                key: const Key('compose-bar-submit'),
                tooltip: 'Send text + Enter',
                color: theme.colorScheme.primary,
                onPressed: () => _send(trailing: '\r'),
                icon: const Icon(Icons.keyboard_return, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
