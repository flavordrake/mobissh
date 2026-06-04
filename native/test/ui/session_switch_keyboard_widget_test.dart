// #741 — widget-level proof that an app-level session-bar swipe-switch PRESERVES
// the keyboard state (focus is retained on the newly-active terminal input, so
// the soft keyboard never collapses and the bar doesn't jump down under the
// finger).
//
// flterm/libghostty can't render headless (native .so), so the per-session
// terminal is stood in by a plain focusable input and the keyboard-up state is
// asserted via `FocusNode.hasFocus` — exactly the proxy the issue prescribes.
// The harness wires the PRODUCTION decision functions
// (ghosttyShouldCaptureKeyboardOnSessionSwitch /
// ghosttyShouldRestoreFocusOnSessionSwitch /
// ghosttyShouldShowKeyboardOnSessionSwitch) and the PRODUCTION
// sessionSwitchKeyboardWasUpProvider to the same `ref.listen` shape the real
// GhosttyTerminalView uses, driven by a REAL horizontal-drag swipe that crosses
// `kSessionSwipeThreshold`. The real soft keyboard staying up on device is
// owner-validated.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/terminal_screen.dart' show kSessionSwipeThreshold;

/// Minimal active-session id store mirroring the real `activeSessionIdProvider`
/// surface the views listen to. Two ids: 's-a' and 's-b'.
final _activeIdProvider = StateProvider<String?>((ref) => 's-a');

/// One session "terminal" stand-in: a focusable input whose [FocusNode.hasFocus]
/// proxies "keyboard up". It runs the SAME switch-focus listen logic the real
/// GhosttyTerminalView runs (production decision fns + provider), so the test
/// exercises the real contract, not a reimplementation of the decision.
class _SwitchFocusKeeper extends ConsumerStatefulWidget {
  const _SwitchFocusKeeper({required this.sessionId, super.key});
  final String sessionId;

  @override
  ConsumerState<_SwitchFocusKeeper> createState() => _SwitchFocusKeeperState();
}

class _SwitchFocusKeeperState extends ConsumerState<_SwitchFocusKeeper> {
  final _focusNode = FocusNode();

  /// Stand-in for the flterm controller's keyboard state: the IME is "up" for a
  /// view exactly while its input holds focus.
  bool get _keyboardWasUp => _focusNode.hasFocus;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(_activeIdProvider, (prev, next) {
      if (ghosttyShouldCaptureKeyboardOnSessionSwitch(
        sessionId: widget.sessionId,
        prevActiveId: prev,
        nextActiveId: next,
      )) {
        ref.read(sessionSwitchKeyboardWasUpProvider.notifier).state =
            _keyboardWasUp;
      }
      if (ghosttyShouldRestoreFocusOnSessionSwitch(
        sessionId: widget.sessionId,
        prevActiveId: prev,
        nextActiveId: next,
      )) {
        // Defer to post-frame so the outgoing view's capture (same provider
        // tick, listener order unspecified) has run and the IndexedStack has put
        // this child onstage — mirroring the real view's post-frame show.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final keyboardWasUp = ref.read(sessionSwitchKeyboardWasUpProvider);
          // Re-attach focus to the incoming input iff the keyboard was up before
          // the switch — the FocusNode.hasFocus proxy for "keyboard stays up".
          if (ghosttyShouldShowKeyboardOnSessionSwitch(
            keyboardWasUp: keyboardWasUp,
          )) {
            _focusNode.requestFocus();
          }
        });
      }
    });
    return Focus(
      focusNode: _focusNode,
      child: SizedBox(
        key: Key('keeper-${widget.sessionId}'),
        width: 200,
        height: 40,
      ),
    );
  }
}

/// A session bar whose horizontal swipe toggles 's-a' <-> 's-b', mirroring the
/// real `_SessionBar` swipe → `setActive` wiring (threshold = the production
/// `kSessionSwipeThreshold`).
class _Harness extends ConsumerStatefulWidget {
  const _Harness();
  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    final activeId = ref.watch(_activeIdProvider);
    final index = activeId == 's-b' ? 1 : 0;
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: index,
                children: const [
                  _SwitchFocusKeeper(sessionId: 's-a', key: Key('body-a')),
                  _SwitchFocusKeeper(sessionId: 's-b', key: Key('body-b')),
                ],
              ),
            ),
            GestureDetector(
              key: const Key('bar'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _dragDx = 0,
              onHorizontalDragUpdate: (d) => _dragDx += d.delta.dx,
              onHorizontalDragEnd: (_) {
                if (_dragDx.abs() < kSessionSwipeThreshold) return;
                final current = ref.read(_activeIdProvider);
                ref.read(_activeIdProvider.notifier).state = current == 's-a'
                    ? 's-b'
                    : 's-a';
              },
              child: const SizedBox(height: 36, width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _swipeBar(WidgetTester tester) async {
  await tester.fling(
    find.byKey(const Key('bar')),
    Offset(-(kSessionSwipeThreshold + 40), 0),
    1000,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('session-bar swipe-switch preserves keyboard state (#741)', () {
    testWidgets('keyboard UP: focus follows to the newly-active terminal', (
      tester,
    ) async {
      await tester.pumpWidget(const ProviderScope(child: _Harness()));
      await tester.pumpAndSettle();

      // Keyboard is "up" on session A: focus its input.
      final aFocus = Focus.of(
        tester.element(find.byKey(const Key('keeper-s-a'))),
      );
      aFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(aFocus.hasFocus, isTrue, reason: 'precondition: keyboard up on A');

      // Swipe the session bar to switch A -> B.
      await _swipeBar(tester);

      // The incoming session (B) now holds focus — the keyboard stayed up and
      // moved to the newly-active terminal (it did NOT collapse).
      final bFocus = Focus.of(
        tester.element(find.byKey(const Key('keeper-s-b'))),
      );
      expect(
        bFocus.hasFocus,
        isTrue,
        reason: 'focus retained on the newly-active terminal (keyboard up)',
      );
    });

    testWidgets('keyboard DOWN: switch leaves the new terminal unfocused', (
      tester,
    ) async {
      await tester.pumpWidget(const ProviderScope(child: _Harness()));
      await tester.pumpAndSettle();

      // No input focused (keyboard down).
      final aFocus = Focus.of(
        tester.element(find.byKey(const Key('keeper-s-a'))),
      );
      expect(aFocus.hasFocus, isFalse, reason: 'precondition: keyboard down');

      await _swipeBar(tester);

      // The incoming terminal is NOT force-focused — the keyboard stays down.
      final bFocus = Focus.of(
        tester.element(find.byKey(const Key('keeper-s-b'))),
      );
      expect(
        bFocus.hasFocus,
        isFalse,
        reason: 'keyboard was down → stays down after the switch',
      );
    });
  });
}
