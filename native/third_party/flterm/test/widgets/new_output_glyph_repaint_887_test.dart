// #887 (P0, device 0.1.10+58) — terminal TEXT invisible: only the
// structured-text HIGHLIGHT decoration paints on new output until a forced
// repaint (route push / scroll / keystroke) makes the glyphs appear.
//
// MECHANISM (pinned here headless):
// The render box's `_onTerminalChanged` handles a terminal notify two ways:
//   - scrollback length UNCHANGED (screen not full) -> `_markFrameDirty()`
//     (which calls `markNeedsPaint`) -> glyphs repaint. Fine.
//   - scrollback length GREW (the screen was full and output pushed rows into
//     history — the common steady-state case) -> it set `_needsFrameSync=true`
//     and called ONLY `markNeedsLayout()`, then returned.
// `markNeedsLayout()` does NOT imply `markNeedsPaint()` in Flutter: the box is
// added to the needs-LAYOUT set, not the needs-PAINT set. `performLayout` then
// runs but only calls `_markFrameDirty()` when the GRID size changed
// (`gridChanged || atlasReconfigured`); for plain streamed output the grid is
// unchanged, so the box is never marked needs-paint. The new glyph rows stay
// unpainted (the `_needsFrameSync` flag just waits) until an UNRELATED event
// forces a paint. Meanwhile the decoration layer repaints independently via the
// controller's `_decorationNotifier`, so the #777 path underline/glyph shows on
// the new rows while the path TEXT itself is blank — exactly the screenshot.
//
// RED on the pre-fix code: after output that grows scrollback, the render box
// is NOT marked needs-paint. GREEN with the fix: the scrollback-grew branch
// also marks the glyph render box needs-paint.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrapInApp(TerminalController controller) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 480,
          child: TerminalView(controller: controller),
        ),
      ),
    );
  }

  testWidgets(
    'new output that grows scrollback marks the glyph render box needs-paint '
    'without a forced repaint (#887)',
    (tester) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrapInApp(controller));
      await tester.pump();

      void write(String s) {
        controller.write(Uint8List.fromList(utf8.encode(s)));
      }

      // Fill the screen and overflow it so the terminal accumulates scrollback
      // history (the steady state when you've been typing in a shell). Pump a
      // settled frame so the painted offset / scrollback bookkeeping catches up
      // and the render box is clean (debugNeedsPaint == false) before the line
      // under test.
      for (var i = 0; i < 60; i++) {
        write('line ${i.toString().padLeft(4, '0')}\r\n');
      }
      await tester.pump();
      await tester.pump();

      final renderBox = tester.renderObject<TerminalRenderBox>(
        find.byType(TerminalRenderer),
      );

      expect(
        controller.scrollbackRows,
        greaterThan(0),
        reason: 'precondition: output overflowed the screen into scrollback',
      );
      expect(
        renderBox.debugNeedsPaint,
        isFalse,
        reason: 'precondition: the frame painted and settled before new output',
      );

      // ONE more line — pushes another row into scrollback (scrollback length
      // grows), the SAME notify path as a freshly-printed prompt line in a
      // full shell. NO scroll, NO keystroke, NO route push afterward.
      final scrollbackBefore = controller.scrollbackRows;
      write('fresh output line that must be painted\r\n');
      expect(
        controller.scrollbackRows,
        greaterThan(scrollbackBefore),
        reason: 'precondition: the new output grew the scrollback length, '
            'taking the markNeedsLayout branch in _onTerminalChanged',
      );

      // THE #887 ASSERTION: the terminal notify fired synchronously inside
      // `write`, running the render box's `_onTerminalChanged`. The glyph
      // render box MUST be marked needs-paint so the new row repaints on the
      // next frame — WITHOUT any forced repaint. Pre-fix this is false (only
      // needs-layout was set), so the glyphs stayed blank until an unrelated
      // event forced a paint.
      expect(
        renderBox.debugNeedsPaint,
        isTrue,
        reason: 'new output must mark the glyph render box needs-paint; the '
            'decoration notify must never be the sole repaint trigger (#887)',
      );
    },
  );
}
