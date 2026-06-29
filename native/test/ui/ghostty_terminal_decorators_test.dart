// #955 — what survives of ghostty_terminal_decorators.dart after the inline
// decorations (URL bubble / path underline painters + GhosttyTerminalDecoratorLayer)
// were RETIRED in favour of the right-edge gutter (ghostty_gutter_layer.dart):
// the shared pattern ids and the (empty) URL highlight style. The gutter widget
// behaviour is covered in ghostty_gutter_layer_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

void main() {
  group('#955 structured-text pattern ids', () {
    test('url / osc8 / path ids are the stable contract', () {
      expect(kGhosttyUrlPatternId, 'url');
      expect(kGhosttyOsc8PatternId, 'osc8');
      expect(kGhosttyPathPatternId, 'path');
    });
  });

  group('#864 URL highlight style', () {
    test('drops the underline AND the fill (no app ink over the glyphs)', () {
      // With the inline bubble retired (#955), the URL affordance is the gutter
      // mark; the pattern must paint NO inline fill/underline of its own.
      expect(kGhosttyUrlHighlightStyle.underline, isNull);
      expect(kGhosttyUrlHighlightStyle.background, isNull);
    });
  });
}
