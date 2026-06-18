// #903 — the ROOT of the terminal repaint-fail saga: the ghostty path sent a
// PTY resize for EVERY flterm `onResize`, and flterm fires `onResize` for every
// LAYOUT CHANGE. A soft-keyboard show/hide animates the viewport inset over many
// frames (per-frame regrid → the `44→43→42→38→37→35→34` storm the tmux-state-
// trace caught), and a window switch reflows ~2 rows transiently (`34→36→34`).
// Each distinct size slipped past the proxy's #848 IDENTICAL-dims no-op guard,
// reached tmux, and raced every redraw — the stale/blank repaint #887/#898/#900
// were chasing at the paint layer.
//
// The fix coalesces the burst: [GhosttyResizeCoalescer] debounces `submit` so a
// PTY resize fires ONCE the size has been STABLE for a settle window that
// outlasts the keyboard animation, sending only the FINAL settled size. A
// transient excursion that returns to the start emits nothing (the window-switch
// blip). The #666/#702 forced resync bypasses the debounce via `flushNow`.
//
// flterm/libghostty can't render headless (native .so), so these drive the PURE
// coalescer directly with a fake scheduler — the storm-vs-bounded behaviour is
// asserted deterministically, with no Timer flakiness. The real on-device
// bounded resize count + repaint is the emulator integration test (red baseline)
// + the owner's `scripts/tmux-state-trace.sh` device validation.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  // A controllable scheduler: each `submit` registers a pending callback; the
  // PREVIOUS pending callback is cancelled (debounce). `settle()` fires the one
  // surviving callback, modelling "the size stopped changing for the window".
  late List<int> sentCols;
  late List<int> sentRows;
  late void Function()? pending;
  late int liveTimers;

  Timer fakeScheduler(Duration _, void Function() cb) {
    pending = cb;
    liveTimers += 1;
    return _FakeTimer(() {
      // A debounce-cancel of THIS timer: if it's still the pending one, drop it.
      if (identical(pending, cb)) pending = null;
      liveTimers -= 1;
    });
  }

  void settle() {
    final cb = pending;
    pending = null;
    if (cb != null) {
      liveTimers -= 1;
      cb();
    }
  }

  GhosttyResizeCoalescer build() => GhosttyResizeCoalescer(
    onSettled: (c, r) {
      sentCols.add(c);
      sentRows.add(r);
    },
    scheduleTimer: fakeScheduler,
  );

  setUp(() {
    sentCols = <int>[];
    sentRows = <int>[];
    pending = null;
    liveTimers = 0;
  });

  group('#903 keyboard-animation storm coalesces to the FINAL size', () {
    test(
      'a 7-frame keyboard-hide cascade sends ONE resize at the final size',
      () {
        final c = build();
        // The exact device-trace shape: a single keyboard-hide animation logged
        // 58×44→43→42→38→37→35→34 in one second. Pre-fix EVERY distinct height
        // reached tmux (7 resizes → 7 regrids racing the redraw). Coalesced, the
        // intermediate frames only RESET the settle timer; only 34 (the final,
        // chrome-correct viewport) is sent.
        for (final rows in [44, 43, 42, 38, 37, 35, 34]) {
          c.submit(58, rows);
        }
        // Mid-animation: nothing has settled yet, so NOTHING has reached the PTY.
        expect(sentRows, isEmpty, reason: 'no PTY resize mid-animation');
        // The inset stops moving → the single surviving debounce fires.
        settle();
        expect(c.sendCount, 1, reason: 'exactly ONE resize for the whole burst');
        expect(sentCols, [58]);
        expect(sentRows, [34], reason: 'the FINAL settled size, not a frame');
      },
    );

    test('each new frame CANCELS the prior pending debounce (no leak)', () {
      final c = build();
      c.submit(58, 44);
      c.submit(58, 38);
      c.submit(58, 34);
      // Three submits, but only ONE timer should be live (each cancels the last).
      expect(liveTimers, 1, reason: 'debounce keeps a single pending timer');
      settle();
      expect(c.sendCount, 1);
      expect(sentRows, [34]);
    });
  });

  group('#903 window-switch blip (transient that returns to base) emits nothing',
      () {
    test('34→36→34 around a window switch coalesces to NO resize', () {
      final c = build();
      // Establish the settled baseline (34) — one real resize.
      c.submit(58, 34);
      settle();
      expect(sentRows, [34]);
      expect(c.sendCount, 1);
      // The window-switch reflow blip: grows 2 rows then returns to 34.
      c.submit(58, 36);
      c.submit(58, 34);
      settle();
      // The settled size equals the last EMITTED size → no spurious resize. The
      // local grid never tells tmux to regrid for a remote window switch.
      expect(c.sendCount, 1, reason: 'the net-zero blip must emit nothing');
      expect(sentRows, [34], reason: 'still only the original resize');
    });

    test('a real size change after a blip DOES send (blip is not sticky)', () {
      final c = build();
      c.submit(58, 34);
      settle();
      // blip
      c.submit(58, 36);
      c.submit(58, 34);
      settle();
      // a genuine keyboard open afterwards
      c.submit(58, 44);
      settle();
      expect(c.sendCount, 2, reason: 'baseline + the genuine 44, not the blip');
      expect(sentRows, [34, 44]);
    });
  });

  group('#903 forced resync (#666/#702) bypasses the debounce', () {
    test('flushNow sends IMMEDIATELY without waiting for settle', () {
      final c = build();
      c.flushNow(58, 34);
      // No settle() call — the forced resync must have sent already.
      expect(c.sendCount, 1, reason: 'forced resync is not debounced');
      expect(sentCols, [58]);
      expect(sentRows, [34]);
    });

    test('flushNow cancels a pending debounce (no double-send)', () {
      final c = build();
      c.submit(58, 40); // a debounce is pending
      expect(liveTimers, 1);
      c.flushNow(58, 34); // forced resync wins + cancels the pending debounce
      expect(c.sendCount, 1);
      expect(sentRows, [34]);
      // The previously-pending debounce must NOT fire a second resize.
      settle();
      expect(c.sendCount, 1, reason: 'flushNow cancelled the pending debounce');
    });

    test(
      'flushNow re-sends the SAME size (the #666 resync re-pushes identical)',
      () {
        final c = build();
        c.submit(58, 34);
        settle();
        expect(c.sendCount, 1);
        // The #666 resync deliberately re-pushes the SAME size once the shell
        // exists — the coalescer must NOT swallow it as a no-op (the proxy owns
        // the one-shot force-bypass of ITS guard).
        c.flushNow(58, 34);
        expect(c.sendCount, 2, reason: 'forced resync re-sends identical dims');
        expect(sentRows, [34, 34]);
      },
    );
  });

  group('#903 settle window outlasts the xterm 120ms', () {
    test('kGhosttyResizeSettle is longer than the xterm metrics settle', () {
      // The #848 xterm `kMetricsSettleDelay` (120ms) was too SHORT — the
      // keyboard animation spans longer, so frames slipped past it (the storm).
      // This window must outlast the soft-keyboard show/hide animation.
      expect(
        kGhosttyResizeSettle.inMilliseconds,
        greaterThan(120),
        reason: 'must outlast the 120ms xterm window that let the storm pass',
      );
    });
  });

  group('#903 cancel drops a pending resize (dispose safety)', () {
    test('cancel() prevents a settled send', () {
      final c = build();
      c.submit(58, 34);
      c.cancel();
      settle(); // nothing pending after cancel
      expect(c.sendCount, 0, reason: 'a cancelled debounce never sends');
      expect(sentRows, isEmpty);
    });
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this._onCancel);
  final void Function() _onCancel;
  bool _active = true;

  @override
  void cancel() {
    if (_active) {
      _active = false;
      _onCancel();
    }
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
