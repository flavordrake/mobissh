// #955/#988 — the shared decorator contract in ghostty_terminal_decorators.dart:
// the pattern ids and the (empty) URL highlight style. The style stays EMPTY
// even with the inline bubble RESTORED (#988): the bubble is a WIDGET-layer
// decorator (GhosttyBubbleLayer, covered in ghostty_bubble_layer_test.dart),
// never a per-glyph fill; the gutter widget behaviour is covered in
// ghostty_gutter_layer_test.dart.

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
      // The URL affordances (bubble #988 + gutter mark #955) are widget-layer
      // decorators; the pattern must paint NO per-glyph fill/underline of its own.
      expect(kGhosttyUrlHighlightStyle.underline, isNull);
      expect(kGhosttyUrlHighlightStyle.background, isNull);
    });
  });

  // #990 visibility gate: single-segment root-level matches (`/word`) are
  // overwhelmingly TUI slash-commands (`/config`, `/rc` — the +121 owner
  // report), not paths. They get NO affordance until an SFTP stat confirms
  // they exist. Multi-segment paths never require verification to SHOW.
  group('#990 ghosttyPathRequiresVerification', () {
    test('single-segment root matches require verification', () {
      expect(ghosttyPathRequiresVerification('/config'), isTrue);
      expect(ghosttyPathRequiresVerification('/rc'), isTrue);
      expect(ghosttyPathRequiresVerification('/etc'), isTrue);
      // Trailing slash doesn't add a segment.
      expect(ghosttyPathRequiresVerification('/etc/'), isTrue);
    });

    test('multi-segment paths do NOT require verification to show', () {
      expect(ghosttyPathRequiresVerification('/etc/hosts'), isFalse);
      expect(ghosttyPathRequiresVerification('/no/such/path990'), isFalse);
      expect(ghosttyPathRequiresVerification('/a/b/'), isFalse);
    });

    test('degenerate payloads are conservative (suppressed until verified)', () {
      expect(ghosttyPathRequiresVerification('/'), isTrue);
      expect(ghosttyPathRequiresVerification(''), isTrue);
    });
  });
}
