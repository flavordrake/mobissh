// Shared raw-libghostty probe helpers for the paint replay harness tests
// (render_state_foreign_consume_test.dart, controller_no_damage_consume_test.dart).

import 'dart:convert';
import 'dart:typed_data';

// ignore_for_file: depend_on_referenced_packages
// (libghostty is reached through the vendored flterm.)
import 'package:libghostty/libghostty.dart';

/// Read the full text of viewport row [rowIndex] from [rs]'s snapshot —
/// the content a render pass over this handle would paint.
String rowText(RenderState rs, int rowIndex) {
  final rows = RowIterator();
  final cells = CellIterator();
  try {
    rows.reset(rs);
    var i = 0;
    while (rows.next()) {
      if (i == rowIndex) {
        final buf = StringBuffer();
        cells.reset(rows);
        while (cells.next()) {
          if (cells.hasText) buf.write(cells.content);
        }
        return buf.toString();
      }
      i++;
    }
    return '';
  } finally {
    cells.dispose();
    rows.dispose();
  }
}

/// UTF-8 bytes of [s].
Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
