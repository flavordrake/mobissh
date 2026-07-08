@Tags(['ffi'])
library;

// PAINT-STALENESS ROOT FIX regression (owner report 2026-07-08T00-51-01,
// "paint not happening again"; saga #887/#898/#900/#918/#921/#922/#931).
//
// render_state_foreign_consume_test.dart proves the libghostty substrate:
// a RenderState whose `update()` runs AFTER another handle consumed the
// terminal's per-row damage keeps serving STALE row content. So ANY
// controller-side `RenderState.update` (visibleRowsText, anchor geometry, the
// #873 synchronous prune that runs on EVERY notify while an anchor is live —
// e.g. a URL sitting on screen, like the PowerShell banner in the owner's
// report) could starve the render box's paint snapshot: telemetry said
// `sync rebuilt=34` while the glass stayed frozen pre-typing.
//
// The fix removes EVERY RenderState from the controller (dims now come from
// the handleResize-fed cache; content reads were already live GridRef /
// Formatter queries). This test pins the invariant at the flterm level: a
// simulated PAINT HANDLE (raw RenderState, exactly what the render box's
// frame builder owns) must keep seeing CURRENT row content across controller
// read/notify activity that used to consume the damage.
//
// RED before the fix (both probes served the pre-write content), GREEN after.

// ignore_for_file: depend_on_referenced_packages, implementation_imports
// ignore_for_file: invalid_use_of_internal_member
// (libghostty + the controller impl are reached through the vendored flterm;
// the impl import mirrors flterm's own tests and exposes `.terminal`, which
// the public interface deliberately hides from production callers.)

import 'package:flterm/flterm.dart';
import 'package:flterm/src/widgets/terminal_controller_impl.dart'
    show TerminalControllerImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart' show RenderState;

import 'render_state_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('visibleRowsText between writes does NOT starve the paint handle', () {
    final controller = TerminalControllerImpl(
      config: const TerminalConfig(cols: 40, rows: 6),
    );
    addTearDown(controller.dispose);
    final paintHandle = RenderState();
    addTearDown(paintHandle.dispose);

    controller.write(bytes('AAA'));
    paintHandle.update(controller.terminal);
    expect(rowText(paintHandle, 0), contains('AAA'));

    // In-place PSReadLine-style redraw of row 0.
    controller.write(bytes('\r\x1b[KBBB'));
    // The controller read that used to run RenderState.update (consuming the
    // shared damage) before the paint handle's sync.
    final live = controller.visibleRowsText(0, 5);
    expect(live, contains('BBB'), reason: 'live model read must be current');

    paintHandle.update(controller.terminal);
    expect(
      rowText(paintHandle, 0),
      contains('BBB'),
      reason: 'STALE PAINT SNAPSHOT: a controller visibleRowsText read '
          'consumed the damage and starved the paint handle (the frozen-glass '
          'root). The controller must not own any RenderState.',
    );
  });

  test('live URL anchor + every-notify prune does NOT starve the paint handle',
      () async {
    final controller = TerminalControllerImpl(
      config: const TerminalConfig(cols: 60, rows: 8),
    );
    addTearDown(controller.dispose);
    final paintHandle = RenderState();
    addTearDown(paintHandle.dispose);

    // A URL on screen = a LIVE anchor once the debounced rescan fires — the
    // owner's PowerShell banner state. From then on the #873 prune runs
    // synchronously on EVERY terminal notify.
    controller.registerTextPattern(TextPattern.url(id: 'url'));
    controller.write(bytes('see https://aka.ms/PSWindows now\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(controller.anchors, isNotEmpty,
        reason: 'precondition: the URL anchor must be live so the prune runs');

    paintHandle.update(controller.terminal);

    // Stream more output — every write fires a notify → synchronous prune.
    for (var i = 0; i < 5; i++) {
      controller.write(bytes('line$i\r\n'));
    }
    controller.write(bytes('MARKER_END_91\r\n'));

    paintHandle.update(controller.terminal);
    final rows = List.generate(8, (r) => rowText(paintHandle, r)).join('\n');
    expect(
      rows,
      contains('MARKER_END_91'),
      reason: 'STALE PAINT SNAPSHOT: with a live anchor, the every-notify '
          'prune consumed the damage and the paint handle kept the pre-stream '
          'content (sync rebuilt=N with a frozen glass — the '
          '2026-07-08T00-51-01 signature).',
    );
  });
}
