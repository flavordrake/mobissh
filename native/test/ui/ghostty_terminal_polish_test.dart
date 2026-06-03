// #686 — Ghostty backend polish: per-session font/size + scroll-vs-select.
//
// The flterm/libghostty widget can't render headless (needs the native .so), so
// these gate the PURE wiring the view feeds flterm:
//   1. [buildGhosttyTheme] maps the per-session font family + size onto flterm's
//      `TerminalTheme` (where flterm carries the font, NOT a separate textStyle)
//      and defaults to the readable bundled JetBrainsMono face.
//   2. [kGhosttyScrollSettings] (#688/#692): the scroll-only settings drop BOTH
//      `drag` and `longPress` (so a swipe scrolls, never drag-selects). #692
//      removed the opt-in select-mode settings — a deliberate touch long-press-
//      drag now drives a remote selection via the gesture-router overlay, not an
//      flterm-native gesture.
//
// `TerminalTheme` + `TerminalGestureSettings` are pure Dart value objects (no
// FFI at construction), so this runs without the native libghostty .so. The
// actual on-device gestures/font are OWNER-validated.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('buildGhosttyTheme — per-session font + size (#686 fix 1)', () {
    test('applies the requested family and size to the flterm theme', () {
      final theme = buildGhosttyTheme(family: 'FiraCode', fontSize: 18);
      expect(theme.fontFamily, 'FiraCode');
      expect(theme.fontSize, 18);
    });

    test(
      'a second family/size produces an independent (per-session) theme',
      () {
        final a = buildGhosttyTheme(family: 'JetBrainsMono', fontSize: 14);
        final b = buildGhosttyTheme(family: 'CascadiaCode', fontSize: 22);
        expect(a.fontFamily, 'JetBrainsMono');
        expect(a.fontSize, 14);
        expect(b.fontFamily, 'CascadiaCode');
        expect(b.fontSize, 22);
        // No shared mutable state — building one must not change the other.
        expect(a.fontFamily, isNot(b.fontFamily));
      },
    );

    test('the bundled default family is JetBrainsMono (readable mono)', () {
      // The view feeds this from the #679 provider whose default is
      // [fontFamilyDefault]; a session with that default must render the
      // bundled JetBrainsMono face (the prior hardcoded thin default was the
      // device complaint).
      expect(fontFamilyDefault, 'JetBrainsMono');
      final theme = buildGhosttyTheme(
        family: fontFamilyDefault,
        fontSize: fontSizeDefault,
      );
      expect(theme.fontFamily, 'JetBrainsMono');
      expect(theme.fontSize, fontSizeDefault);
    });

    test('keeps the dark palette + emoji/mono fallback chain from dark()', () {
      final theme = buildGhosttyTheme(family: 'JetBrainsMono', fontSize: 14);
      final base = TerminalTheme.dark();
      // Only font face + size are overridden; palette + fallback are inherited.
      expect(theme.background, base.background);
      expect(theme.foreground, base.foreground);
      expect(theme.fontFamilyFallback, base.fontFamilyFallback);
    });

    test('every bundled family id builds a theme that carries that id', () {
      for (final f in terminalFontFamilies) {
        final theme = buildGhosttyTheme(family: f.id, fontSize: 16);
        expect(theme.fontFamily, f.id);
      }
    });
  });

  group('kGhosttyScrollSettings — swipe = scroll-only (#688)', () {
    test('does NOT enable drag-select (mouse drag scrolls)', () {
      expect(
        kGhosttyScrollSettings.enabledSelections,
        isNot(contains(SelectionGesture.drag)),
        reason: 'drag must scroll the scrollback, not start a selection',
      );
    });

    test('does NOT enable long-press (the #688 swipe drag-select culprit)', () {
      // flterm gives long-press to TOUCH pointers; on a swipe the start-of-
      // swipe dwell wins the arena and drag-selects. Dropping it makes a
      // swipe scroll-only.
      expect(
        kGhosttyScrollSettings.enabledSelections,
        isNot(contains(SelectionGesture.longPress)),
        reason: 'a finger swipe must scroll, never long-press drag-select',
      );
    });

    test(
      'keeps discrete-tap word/line + select-all (never fire on a swipe)',
      () {
        expect(
          kGhosttyScrollSettings.enabledSelections,
          containsAll(const {
            SelectionGesture.word,
            SelectionGesture.line,
            SelectionGesture.selectAll,
          }),
        );
      },
    );

    test('is strictly the all-set minus drag AND longPress', () {
      expect(
        kGhosttyScrollSettings.enabledSelections,
        SelectionGesture.all.difference({
          SelectionGesture.drag,
          SelectionGesture.longPress,
        }),
      );
    });

    test('line selection grabs the full row (fuller selection control)', () {
      expect(kGhosttyScrollSettings.lineSelectMode, LineSelectMode.full);
    });
  });
}
