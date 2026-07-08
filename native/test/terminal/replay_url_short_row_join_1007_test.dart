@Tags(['ffi'])
library;

// REPLAY regression for #1007 — the width-heuristic wrap-join glued the next
// line's leading `1` onto a URL whose row NEVER reached a wrap boundary.
//
// Found by the #993 agent's emulator run: `SOMETEXT https://example.com/track993`
// is 38 cols in a 55-col grid — provably NOT soft-wrapped (17 cols of headroom)
// — yet the anchor payload came back `…/track9931`. Root cause: `_inferWrapCol`
// takes the MODE of content-end columns among long rows, and with this row as
// the ONLY sample its own end (38) became the "inferred wrap column", making the
// `end >= wrapCol - 1` reach test vacuously true (self-corroboration). The #1007
// guard demands the boundary be corroborated by a SECOND row (a consistent app
// content width) or sit at the grid edge (the terminal itself wraps there).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'https://example.com/track993';

  group('REPLAY #1007 — short row must not width-join', () {
    test(
      'a 38-col URL line in a 55-col grid followed by a line starting with `1` '
      'anchors EXACTLY the URL (no glued `1` from the next line)',
      () async {
        final controller = TerminalController(
          config: const TerminalConfig(cols: 55, rows: 20),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.url());

        // The exact #993 shape: a 38-col line — far short of both the terminal
        // width (55) and any real app wrap column — hard-terminated by CRLF,
        // followed by a line whose first glyph is a bare `1` (not a bullet, not
        // a scheme, same col-0 margin: every pre-#1007 join gate passed).
        controller.write(
          Uint8List.fromList(
            utf8.encode('SOMETEXT $url\r\n1 more output line\r\n'),
          ),
        );
        // Detection re-scan is debounced (~120ms); mirror the sibling replay
        // tests' 250ms settle.
        await Future<void>.delayed(const Duration(milliseconds: 250));

        final urlAnchors = controller.anchors
            .where((a) => a.patternId == 'url')
            .toList();
        expect(
          urlAnchors,
          hasLength(1),
          reason: 'exactly one URL anchor on the grid',
        );
        expect(
          urlAnchors.single.payload,
          url,
          reason: 'the payload must be EXACTLY the printed URL — the #1007 bug '
              'wrap-joined the next line and produced …/track9931',
        );
      },
    );
  });
}
