// #708 — Ghostty swipe AXIS-LOCK: a gesture must commit to ONE axis and ignore
// the other for its whole duration, so a horizontal (tab-switch) swipe never
// scrolls on slight vertical jitter and a vertical scroll never tab-switches on
// horizontal drift.
//
// The active overlay used to run two INDEPENDENT drag recognisers competing in
// the gesture arena (Vertical → scroll #690, Horizontal → window-switch #702),
// which committed to whichever crossed ITS slop first, blind to the other axis.
// The fix is a single pan tracker + the PURE [ghosttyAxisLock] decision below.
// flterm/libghostty can't render headless (native .so), so we gate the pure
// axis-lock math here; the real touch behaviour is OWNER-validated on device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  const slop = kGhosttySwipeAxisLockSlop; // 12.0
  const ratio = kGhosttySwipeAxisLockRatio; // 1.5

  group('ghosttyAxisLock — slop gate (#708)', () {
    test('travel below the slop does NOT commit (tiny jitter ignored)', () {
      // A few px of jitter at the very start of a touch must not commit either
      // axis — the gesture stays uncommitted until it travels enough.
      expect(
        ghosttyAxisLock(3, 1, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
      expect(
        ghosttyAxisLock(0, 0, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
      // Just under the slop circle (hypot(8,8)=11.3 < 12) → still none.
      expect(
        ghosttyAxisLock(8, 8, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
    });

    test('travel past the slop with a clear axis commits', () {
      // hypot(20,2)=20.1 ≥ 12 and 20 ≥ 2*1.5 → horizontal.
      expect(
        ghosttyAxisLock(20, 2, slop: slop, ratio: ratio),
        GhosttySwipeAxis.horizontal,
      );
    });
  });

  group('ghosttyAxisLock — clear single-axis swipes (#708)', () {
    test('a clear HORIZONTAL swipe → horizontal (no scroll leak)', () {
      // The device-log case: net dx≈-114, dy≈0 (pure horizontal). Must lock H.
      expect(
        ghosttyAxisLock(-114, 0, slop: slop, ratio: ratio),
        GhosttySwipeAxis.horizontal,
      );
      expect(
        ghosttyAxisLock(40, 5, slop: slop, ratio: ratio),
        GhosttySwipeAxis.horizontal,
      );
    });

    test('a clear VERTICAL swipe → vertical (no tab-switch leak)', () {
      expect(
        ghosttyAxisLock(0, -80, slop: slop, ratio: ratio),
        GhosttySwipeAxis.vertical,
      );
      expect(
        ghosttyAxisLock(5, 40, slop: slop, ratio: ratio),
        GhosttySwipeAxis.vertical,
      );
    });

    test('direction sign does not matter — magnitude decides the axis', () {
      for (final dx in const [50.0, -50.0]) {
        expect(
          ghosttyAxisLock(dx, 4, slop: slop, ratio: ratio),
          GhosttySwipeAxis.horizontal,
        );
      }
      for (final dy in const [50.0, -50.0]) {
        expect(
          ghosttyAxisLock(4, dy, slop: slop, ratio: ratio),
          GhosttySwipeAxis.vertical,
        );
      }
    });
  });

  group('ghosttyAxisLock — diagonal / ambiguous stays uncommitted (#708)', () {
    test('a 45° diagonal does NOT commit (neither axis dominates)', () {
      // dx==dy: dominant 20 < 20*1.5 → none. The gesture waits to resolve.
      expect(
        ghosttyAxisLock(20, 20, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
    });

    test('a near-diagonal below the ratio stays none', () {
      // 18 vs 14: 18 < 14*1.5(=21) → none even though past the slop.
      expect(
        ghosttyAxisLock(18, 14, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
      expect(
        ghosttyAxisLock(14, 18, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
    });

    test('exactly at the ratio boundary commits (>= is inclusive)', () {
      // dominant == ratio*offAxis → commits to the dominant axis.
      expect(
        ghosttyAxisLock(15, 10, slop: slop, ratio: ratio),
        GhosttySwipeAxis.horizontal,
      );
      expect(
        ghosttyAxisLock(10, 15, slop: slop, ratio: ratio),
        GhosttySwipeAxis.vertical,
      );
    });

    test('just past the ratio commits, just under does not', () {
      // 15.1 vs 10 → 15.1 ≥ 15 → horizontal.
      expect(
        ghosttyAxisLock(15.1, 10, slop: slop, ratio: ratio),
        GhosttySwipeAxis.horizontal,
      );
      // 14.9 vs 10 → 14.9 < 15 → none.
      expect(
        ghosttyAxisLock(14.9, 10, slop: slop, ratio: ratio),
        GhosttySwipeAxis.none,
      );
    });
  });

  group(
    'ghosttyAxisLock — off-axis jitter does not flip a clear axis (#708)',
    () {
      test('a long horizontal swipe tolerates real-world vertical wobble', () {
        // A deliberate left/right flick with a few px of vertical wander still
        // locks horizontal — this is the regression #708 reported (scroll leak).
        expect(
          ghosttyAxisLock(100, 30, slop: slop, ratio: ratio),
          GhosttySwipeAxis.horizontal,
        );
      });

      test('a long vertical scroll tolerates real-world horizontal wobble', () {
        // A scroll with a few px of horizontal drift still locks vertical — the
        // other half of #708 (window-switch leak).
        expect(
          ghosttyAxisLock(30, 100, slop: slop, ratio: ratio),
          GhosttySwipeAxis.vertical,
        );
      });
    },
  );

  group('GhosttySwipeAxis enum (#708)', () {
    test('has exactly the three commit states', () {
      expect(GhosttySwipeAxis.values, <GhosttySwipeAxis>[
        GhosttySwipeAxis.none,
        GhosttySwipeAxis.horizontal,
        GhosttySwipeAxis.vertical,
      ]);
    });
  });
}
