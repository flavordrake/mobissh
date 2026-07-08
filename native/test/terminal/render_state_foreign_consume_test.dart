@Tags(['ffi'])
library;

// PAINT REPLAY HARNESS — substrate-constraint probe for the "paint not
// happening" class (owner report 2026-07-08T00-51-01; saga
// #887/#898/#900/#918/#921/#922/#931).
//
// DISCOVERY (2026-07-08, deterministic, headless): when a SECOND RenderState
// handle consumes the shared terminal's damage first, the paint handle's next
// `update()` — even while reporting a NON-clean DirtyState — keeps serving its
// OLD row content. Row-content refresh inside libghostty's
// `renderStateUpdate` is gated on the terminal's per-row damage, which is
// single-consumption across ALL handles. So any full flterm re-read
// (markAllRowsDirty, #900/#921/#922) off a starved handle repaints STALE
// cells: `sync rebuilt=N` telemetry with a frozen glass — the owner's exact
// signature (detection ON + the PowerShell banner URL = a live anchor = the
// controller's every-notify prune consuming the damage first).
//
// This test PINS that substrate behavior as an architectural CONSTRAINT:
// flterm must keep exactly ONE RenderState per terminal (the render box's
// frame builder; see terminal_controller_impl.dart, which now owns none). If
// this test ever FAILS (a libghostty upgrade makes foreign-consumed handles
// content-current), the single-consumer constraint can be revisited.
//
// The enforced production invariant lives in
// controller_no_damage_consume_test.dart.

import 'package:flutter_test/flutter_test.dart';
// ignore_for_file: depend_on_referenced_packages
// (libghostty is reached through the vendored flterm.)
import 'package:libghostty/libghostty.dart';

import 'render_state_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CONSTRAINT: a foreign damage consume leaves other handles serving '
      'stale row content', () {
    final t = Terminal(cols: 20, rows: 4);
    final paintHandle = RenderState();
    final foreignHandle = RenderState();
    addTearDown(() {
      paintHandle.dispose();
      foreignHandle.dispose();
    });

    t.write(bytes('AAA'));
    final first = paintHandle.update(t);
    expect(rowText(paintHandle, 0), contains('AAA'));
    expect(first, isNot(DirtyState.clean));

    // Overwrite row 0 in place (PSReadLine shape: CR + clear-line + redraw).
    t.write(bytes('\r\x1b[KBBB'));

    // A FOREIGN handle consumes the shared damage first...
    foreignHandle.update(t);
    expect(rowText(foreignHandle, 0), contains('BBB'),
        reason: 'the consuming handle itself sees the new content');

    // ...and the paint handle's subsequent update KEEPS THE OLD CELLS, no
    // matter what DirtyState it reports. This is WHY the controller may own
    // no RenderState: one terminal, one consumer.
    final second = paintHandle.update(t);
    final seen = rowText(paintHandle, 0);
    expect(
      seen,
      isNot(contains('BBB')),
      reason: 'libghostty now refreshes foreign-consumed snapshots '
          '(update reported "$second") — the single-RenderState-per-terminal '
          'constraint in flterm can be revisited. Until then this documents '
          'the substrate the 2026-07-08T00-51-01 freeze grew from.',
    );
    expect(seen, contains('AAA'));
  });
}
