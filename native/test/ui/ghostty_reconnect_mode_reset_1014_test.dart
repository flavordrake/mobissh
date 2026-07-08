@Tags(['ffi'])
library;

// #1014 — stale mouse-reporting mode after reconnect: the app kept synthesizing
// SGR mouse reports into a REVIVED session whose remote no longer had mouse
// mode enabled, landing as literal `[<65;...M` text at the prompt.
//
// ROOT CAUSE: the flterm controller (and the libghostty VT terminal under it)
// SURVIVES a reconnect — only the task-side shell reopens. The terminal's DEC
// private modes (9/1000/1002/1003 → `mouseTracking`, plus 1005/1006/1015
// encodings, 1007 alternate scroll, 2004 bracketed paste) are set by the
// PRE-DROP remote's byte stream and nothing resets them at the revive boundary,
// so `_mouseTracking` stays on and the gesture overlay keeps forwarding SGR.
//
// FIX: at the revive seam (`proxy.shellReady`, which re-fires on every
// reconnect — the same seam the #702 resize-resync and #717 focus latch use)
// the view writes [ghosttyInputModeResetSequence] (DECRST for every
// synthesized-input-gating DEC private mode) LOCALLY into the terminal parser.
// The remote re-enables the modes through the byte stream if its TUI is still
// alive (tmux re-attach re-emits DECSET on redraw) — the parser picks that up
// naturally. Ordering is safe: shellReady and output events share one IPC
// stream, so the reset always lands before the revived shell's first output.
//
// These are STATE-TRANSITION tests (rules/state-management.md) against the REAL
// libghostty parser (ffi tag, runs in gate 2): connected(TUI, mouse on) → drop →
// reconnect(plain shell) → the reset drives tracking to none (gestures stop
// forwarding SGR) → the remote re-enables via bytes → gestures forward again.
// The shellReady wiring itself is covered on-emulator by
// integration_test/reconnect_mouse_mode_1014_test.dart.

// ignore_for_file: depend_on_referenced_packages, implementation_imports
// ignore_for_file: invalid_use_of_internal_member
// (The controller impl import mirrors flterm's own tests and exposes
// `.terminal` for direct mode assertions; production callers use the public
// interface.)

import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flterm/src/widgets/terminal_controller_impl.dart'
    show TerminalControllerImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

/// tmux-style mouse-mode enable: button tracking + SGR encoding (what
/// `set -g mouse on` emits on attach).
const String kTmuxMouseOn = '\x1b[?1002h\x1b[?1006h';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#1014 revive-boundary input-mode reset (state transitions)', () {
    test(
        'connected(TUI, mouse ON) → revive reset → tracking none and the '
        'swipe gate stops forwarding SGR', () {
      final controller = TerminalControllerImpl(
        config: const TerminalConfig(cols: 80, rows: 24),
      );
      addTearDown(controller.dispose);

      // Pre-drop remote: a mouse-reporting TUI (tmux, mouse on).
      controller.write(bytes(kTmuxMouseOn));
      expect(controller.mouseTracking, MouseTracking.button,
          reason: 'precondition: DECSET 1002 must enable button tracking');
      expect(
        ghosttySwipeShouldScrollLocally(
          mouseTracking: controller.mouseTracking,
        ),
        isTrue,
        reason: 'precondition: mouse mode on → overlay intercepts + '
            'synthesizes SGR (existing behavior)',
      );

      // Drop → reconnect: the revived remote is a PLAIN shell. The view writes
      // the reset sequence at shellReady; the parser must drive tracking to
      // none so no further SGR is synthesized.
      controller.write(bytes(ghosttyInputModeResetSequence));
      expect(
        controller.mouseTracking,
        MouseTracking.none,
        reason: 'STALE MODE (#1014): the revive reset did not clear mouse '
            'tracking — gestures would keep sending SGR into the plain shell '
            'as literal [<65;...M text',
      );
      expect(
        ghosttySwipeShouldScrollLocally(
          mouseTracking: controller.mouseTracking,
        ),
        isFalse,
        reason: 'after the reset a swipe must scroll locally, never forward',
      );
    });

    test('remote re-enables via the byte stream → gestures forward again', () {
      final controller = TerminalControllerImpl(
        config: const TerminalConfig(cols: 80, rows: 24),
      );
      addTearDown(controller.dispose);

      controller.write(bytes(kTmuxMouseOn));
      controller.write(bytes(ghosttyInputModeResetSequence));
      expect(controller.mouseTracking, MouseTracking.none);

      // The revived remote's TUI is still alive (e.g. tmux auto-attach): its
      // redraw re-emits DECSET AFTER the reset — the parser must pick it up
      // with no user action.
      controller.write(bytes(kTmuxMouseOn));
      expect(controller.mouseTracking, MouseTracking.button,
          reason: 'a re-attached TUI re-enabling mouse mode must re-arm the '
              'SGR path without user action');
      expect(
        ghosttySwipeShouldScrollLocally(
          mouseTracking: controller.mouseTracking,
        ),
        isTrue,
      );
    });

    test('reset clears EVERY synthesized-input-gating DEC private mode', () {
      final controller = TerminalControllerImpl(
        config: const TerminalConfig(cols: 80, rows: 24),
      );
      addTearDown(controller.dispose);

      // Enable every mode the reset claims to cover: all four tracking
      // variants would overwrite each other's report semantics, so set the
      // strongest (any-motion) + the encodings + scroll/paste modes.
      controller.write(
        bytes('\x1b[?1003h\x1b[?1005h\x1b[?1006h\x1b[?1015h'
            '\x1b[?1007h\x1b[?2004h'),
      );
      expect(controller.mouseTracking, MouseTracking.any);
      expect(
        controller.terminal.modeGet(const TerminalMode.alternateScroll()),
        isTrue,
      );
      expect(
        controller.terminal.modeGet(const TerminalMode.bracketedPaste()),
        isTrue,
      );

      controller.write(bytes(ghosttyInputModeResetSequence));

      expect(controller.mouseTracking, MouseTracking.none);
      for (final (mode, name) in <(TerminalMode, String)>[
        (const TerminalMode.x10Mouse(), 'x10Mouse (9)'),
        (const TerminalMode.normalMouse(), 'normalMouse (1000)'),
        (const TerminalMode.buttonMouse(), 'buttonMouse (1002)'),
        (const TerminalMode.anyMouse(), 'anyMouse (1003)'),
        (const TerminalMode.utf8Mouse(), 'utf8Mouse (1005)'),
        (const TerminalMode.sgrMouse(), 'sgrMouse (1006)'),
        (const TerminalMode.urxvtMouse(), 'urxvtMouse (1015)'),
        (const TerminalMode.alternateScroll(), 'alternateScroll (1007)'),
        (const TerminalMode.bracketedPaste(), 'bracketedPaste (2004)'),
      ]) {
        expect(
          controller.terminal.modeGet(mode),
          isFalse,
          reason: '$name must be reset at the revive boundary',
        );
      }
    });

    test('reset is LOCAL-only: nothing is emitted toward the remote, and it '
        'is a no-op on a default-mode (first-connect) terminal', () {
      final controller = TerminalControllerImpl(
        config: const TerminalConfig(cols: 80, rows: 24),
      );
      addTearDown(controller.dispose);
      final emitted = <int>[];
      controller.onOutput = emitted.addAll;

      // First connect: modes are already default — the unconditional reset at
      // shellReady must be harmless.
      controller.write(bytes(ghosttyInputModeResetSequence));
      expect(controller.mouseTracking, MouseTracking.none);
      expect(
        emitted,
        isEmpty,
        reason: 'the revive reset must never SEND bytes to the remote — it '
            'only re-syncs the LOCAL parser state',
      );
    });
  });
}
