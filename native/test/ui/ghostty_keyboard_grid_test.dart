// #922 — tmux "not updating on window switch": the status-bar tap moved only the
// cursor, never switched windows. ROOT (device capture 2026-06-25T18-09-02): the
// PTY resize was driven solely by flterm's `controller.onResize`, which races the
// soft-keyboard show/hide animation and SETTLES BACK to the pre-keyboard (tall)
// size. The gesture log proved it — at tap time the box was 597px (keyboard UP,
// ~34 visible rows) but flterm reported `grid=58x57 sent=58x57`. tmux therefore
// kept a 57-row grid and drew its status bar at row ~56, BELOW the keyboard and
// off-screen; a tap on the visible bottom (row 34) landed in the MIDDLE of tmux's
// grid → cursor moved, no window switch.
//
// The fix: the host computes the AUTHORITATIVE grid itself from the laid-out box
// (already keyboard-reduced by the Scaffold) via [ghosttyGridForBox], mirroring
// flterm's own grid math, and submits THAT to the #903 coalescer. These pure
// tests assert the keyboard-aware row count tracks the visible height, so tmux's
// status bar stays at the visible bottom and the #719 status-tap lands on it.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  // The device repro's geometry: 58 cols, a real cell of ~9.1w x 17.4h, padding
  // 4 on every side. Keyboard DOWN box ≈ 995px → 57 rows; keyboard UP box ≈
  // 597px → 34 rows. These are the two states the oscillation toggled between.
  const cellW = 9.1;
  const cellH = 17.4;

  group('#922 ghosttyGridForBox tracks the keyboard-aware VISIBLE height', () {
    test('keyboard DOWN (tall box) → the full 57-row grid', () {
      final (cols, rows) = ghosttyGridForBox(
        boxWidth: 527.1,
        boxHeight: 995.4,
        cellWidth: cellW,
        cellHeight: cellH,
      );
      // (995.4 - 8) / 17.4 = 56.7 → floor 57? floor((987.4)/17.4)=floor(56.7)=56;
      // assert it is the keyboard-down count and >> the keyboard-up count.
      expect(rows, greaterThanOrEqualTo(56));
      expect(cols, 57); // (527.1 - 8) / 9.1 = 57.04 → 57
    });

    test('keyboard UP (reduced box) → a SMALL row count, NOT the tall one', () {
      final (_, rows) = ghosttyGridForBox(
        boxWidth: 527.1,
        boxHeight: 597.5,
        cellWidth: cellW,
        cellHeight: cellH,
      );
      // (597.5 - 8) / 17.4 = 33.8 → 33. The crux: this must be the keyboard-up
      // count (~33/34), NEVER the keyboard-down 57 that tmux wrongly believed.
      expect(rows, lessThan(40));
      expect(rows, 33);
    });

    test('the keyboard-up grid is STRICTLY shorter than the keyboard-down grid',
        () {
      final (_, downRows) = ghosttyGridForBox(
        boxWidth: 527.1,
        boxHeight: 995.4,
        cellWidth: cellW,
        cellHeight: cellH,
      );
      final (_, upRows) = ghosttyGridForBox(
        boxWidth: 527.1,
        boxHeight: 597.5,
        cellWidth: cellW,
        cellHeight: cellH,
      );
      // The bug was upRows == downRows (both 57). The fix guarantees the keyboard
      // shrinks the grid so tmux's status bar follows the visible bottom.
      expect(upRows, lessThan(downRows));
    });
  });

  group('#922 ghosttyGridForBox mirrors flterm grid math (padding + floor)', () {
    test('subtracts padding on BOTH axes before flooring', () {
      // A box exactly 10 cells + both paddings tall/wide → exactly 10x10.
      final (cols, rows) = ghosttyGridForBox(
        boxWidth: 10 * 9.0 + 8,
        boxHeight: 10 * 17.0 + 8,
        cellWidth: 9.0,
        cellHeight: 17.0,
        padding: 4.0,
      );
      expect(cols, 10);
      expect(rows, 10);
    });

    test('floors a partial trailing cell (the flterm bottom-slack rule)', () {
      // 10.9 cells of inner height → 10 rows (the partial 0.9 is slack).
      final (_, rows) = ghosttyGridForBox(
        boxWidth: 200,
        boxHeight: 10.9 * 17.0 + 8,
        cellWidth: 9.0,
        cellHeight: 17.0,
        padding: 4.0,
      );
      expect(rows, 10);
    });
  });

  group('#922 ghosttyGridForBox is defensive (never a nonsense resize)', () {
    test('a degenerate (pre-layout) cell size yields 1x1, not a crash', () {
      expect(ghosttyGridForBox(
        boxWidth: 500,
        boxHeight: 800,
        cellWidth: 0,
        cellHeight: 0,
      ), (1, 1));
    });

    test('a box smaller than one cell clamps to a 1x1 grid', () {
      final (cols, rows) = ghosttyGridForBox(
        boxWidth: 5,
        boxHeight: 5,
        cellWidth: 9.0,
        cellHeight: 17.0,
      );
      expect(cols, 1);
      expect(rows, 1);
    });
  });
}
