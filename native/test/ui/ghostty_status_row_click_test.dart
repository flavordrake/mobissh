// ghostty_status_row_click_test.dart — the #971 pure routing predicate.
//
// A firm status-bar tap (dwelling past the long-press deadline) used to resolve
// as a text-selection `longpress-select` under tmux mouse mode, so no SGR click
// reached tmux and the window never switched (device telemetry:
// sentSgrTraceEventCount=0, 120 longpress-select events). The fix routes a
// long-press that STARTS on the status row (the last grid row) to the SAME
// click path a tap uses. `ghosttyPressIsStatusRowClick` names that rule and is
// pure, so the boundary is unit-testable headless (the widget wiring +
// end-to-end SGR is covered by integration_test/tmux_status_tap_sgr_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('#971 ghosttyPressIsStatusRowClick', () {
    test('the last grid row (1-based == gridRows) is the status row', () {
      expect(ghosttyPressIsStatusRowClick(row: 25, gridRows: 25), isTrue);
    });

    test('a clamped press at or past the last row still clicks', () {
      // _cellAt clamps to gridRows, but be defensive: >= gridRows is the row.
      expect(ghosttyPressIsStatusRowClick(row: 26, gridRows: 25), isTrue);
    });

    test('a content row (above the status row) is NOT a click → selects', () {
      expect(ghosttyPressIsStatusRowClick(row: 24, gridRows: 25), isFalse);
      expect(ghosttyPressIsStatusRowClick(row: 1, gridRows: 25), isFalse);
    });

    test('a degenerate grid (0 rows, before the first resize) never clicks', () {
      expect(ghosttyPressIsStatusRowClick(row: 0, gridRows: 0), isFalse);
    });
  });
}
