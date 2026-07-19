// #1085 — the `?62c` DA-reply leak reappeared on the desktop-mode transition:
// moving INTO desktop mode is a configuration change (density/screenLayout/size),
// NOT a reconnect, so the #1072 reconnect-settle gate (armed only on shellReady)
// never fires and the terminal's re-probed DA/DSR/mouse replies leak as input.
//
// The fix arms the settle on a real WINDOWING transition, detected in build via
// MediaQuery.size deltas. flterm/libghostty can't render headless, so this gates
// the PURE decision: WHEN a size change is a genuine window transition (vs a
// keyboard toggle, which changes viewInsets not size — never trips this). The
// real controller.beginReconnectSettle() arm is owner-validated on device.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyWindowChangedMaterially (#1085)', () {
    test('first layout (prev null) is not a transition', () {
      expect(
        ghosttyWindowChangedMaterially(null, const Size(400, 800)),
        isFalse,
      );
    });

    test('unchanged size is not a transition', () {
      expect(
        ghosttyWindowChangedMaterially(const Size(400, 800), const Size(400, 800)),
        isFalse,
      );
    });

    test('sub-pixel jitter below epsilon is not a transition', () {
      expect(
        ghosttyWindowChangedMaterially(
          const Size(400, 800),
          const Size(400.4, 799.7),
        ),
        isFalse,
      );
    });

    test('a width jump (phone → desktop-mode freeform) is a transition', () {
      expect(
        ghosttyWindowChangedMaterially(
          const Size(412, 915),
          const Size(1280, 800),
        ),
        isTrue,
      );
    });

    test('rotation (width/height swap) is a transition', () {
      expect(
        ghosttyWindowChangedMaterially(
          const Size(412, 915),
          const Size(915, 412),
        ),
        isTrue,
      );
    });

    test('a keyboard-style height-only change past epsilon still counts as a '
        'window change (keyboard actually uses insets, not size — so in practice '
        'size stays put; this documents the height axis is live)', () {
      expect(
        ghosttyWindowChangedMaterially(
          const Size(400, 800),
          const Size(400, 500),
        ),
        isTrue,
      );
    });
  });
}
