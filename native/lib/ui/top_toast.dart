// Top-anchored transient toast (#667).
//
// All confirmations/errors previously used bottom-anchored Material SnackBars
// (`ScaffoldMessenger.showSnackBar`), which cover the bottom controls — the
// keybar / session bar (#653) / compose bar — on the terminal screen. That's
// premium control real estate. [showTopToast] surfaces the same messages at the
// TOP of the screen instead, below the status bar / notch (safe-area aware).
//
// Implemented as an [OverlayEntry] inserted into the ROOT overlay so it floats
// above every route. It is theme-styled (surfaceContainerHighest / onSurface),
// auto-dismisses after [duration], and is tap-to-dismiss. Only one toast lives
// at a time — a new toast replaces the current one rather than stacking (so
// nothing overflows off-screen).
//
// The feedback overlay (#661/#664) sits ABOVE the Navigator via
// MaterialApp.builder and has no ScaffoldMessenger in its own context, so it
// routes its confirmation through [showTopToastInOverlay] with the navigator's
// own [OverlayState].

import 'dart:async';

import 'package:flutter/material.dart';

/// The single live toast, so a new toast can replace the old one (no stacking).
OverlayEntry? _activeEntry;
Timer? _activeTimer;

/// Show a transient [message] anchored to the TOP of the screen.
///
/// Resolves the root [Overlay] from [context] and delegates to
/// [showTopToastInOverlay]. Safe to call from any widget context that sits
/// under an [Overlay] (the normal case).
void showTopToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return; // no overlay available — nothing to show
  showTopToastInOverlay(overlay, message, duration: duration);
}

/// Show a transient [message] in an explicit [overlay].
///
/// Used by the feedback overlay (#664), which has no ScaffoldMessenger /
/// ambient Overlay in its own builder context and must pass the navigator's
/// [OverlayState] directly.
void showTopToastInOverlay(
  OverlayState overlay,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  // Replace any in-flight toast so we never stack off-screen.
  _dismiss();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _TopToast(
      message: message,
      duration: duration,
      onDismiss: () {
        if (identical(_activeEntry, entry)) {
          _dismiss();
        }
      },
    ),
  );
  _activeEntry = entry;
  overlay.insert(entry);
}

void _dismiss() {
  _activeTimer?.cancel();
  _activeTimer = null;
  _activeEntry?.remove();
  _activeEntry = null;
}

class _TopToast extends StatefulWidget {
  const _TopToast({
    required this.message,
    required this.duration,
    required this.onDismiss,
  });

  final String message;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _timer;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.3),
      end: Offset.zero,
    ).animate(_fade);
    _ctrl.forward();
    _timer = Timer(widget.duration, _exit);
  }

  void _exit() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _timer?.cancel();
    _ctrl.reverse().whenComplete(widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topInset + 12,
      left: 16,
      right: 16,
      child: SafeArea(
        bottom: false,
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: Align(
              alignment: Alignment.topCenter,
              child: GestureDetector(
                key: const Key('top-toast'),
                onTap: _exit,
                child: Material(
                  color: theme.colorScheme.surfaceContainerHighest,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(
                        widget.message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
