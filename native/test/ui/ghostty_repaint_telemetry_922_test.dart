// #922 — the GhosttyTerminalView wires the flterm render box's `onFrameDebug`
// seam to the durable lifecycle ring so a device capture of a stale tmux window
// switch shows WHY a switch didn't repaint.
//
// flterm/libghostty can't render headless (native .so), so the render-box-side
// behaviour (which fields it emits, the collapse) is covered at the flterm level
// in third_party/flterm/test/rendering/frame_debug_telemetry_922_test.dart. Here
// we cover the APP wiring contract: the sink bound to `onFrameDebug`
// ([logRepaintTelemetry]) routes a line into the lifecycle/connect rings tagged
// `[repaint]`, which is exactly what the feedback bundle uploads.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('#922 repaint telemetry wiring', () {
    test(
      'logRepaintTelemetry lands a `[repaint]` line in the durable lifecycle ring '
      '(the ring the feedback bundle uploads) verbatim',
      () {
        const line = 'sync screen=alternate dirty=clean rebuilt=0 '
            'markedAll=t damageUnsettled=f detActive=t';
        logRepaintTelemetry(line);

        final lifecycle = lifecycleLog.value;
        expect(
          lifecycle.any((l) => l.contains('[repaint]') && l.contains(line)),
          isTrue,
          reason: 'the render/sync line is captured under the [repaint] tag in '
              'the lifecycle ring',
        );
      },
    );

    test(
      'a screen-transition line routes through the same sink to the connect ring',
      () {
        logRepaintTelemetry('screen primary->alternate');
        final connect = connectLog.value;
        expect(
          connect.any(
            (l) => l.contains('[repaint]') && l.contains('primary->alternate'),
          ),
          isTrue,
          reason: 'screen transitions also land in the in-context connect ring',
        );
      },
    );
  });
}
