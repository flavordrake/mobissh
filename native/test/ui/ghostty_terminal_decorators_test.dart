// #955/#988/#1045 — the shared decorator contract in
// ghostty_terminal_decorators.dart: the pattern ids and the (empty)
// REGISTRATION highlight style. The registration style stays EMPTY even with
// the wash painted by the fork (#1045): the fill is resolved per ANCHOR via
// the controller's detectionHighlightStyleOf seam (ghostty_wash_style_1045_
// test.dart), never baked into the pattern; the gutter widget behaviour is
// covered in ghostty_gutter_layer_test.dart.

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

  group('#864 URL registration style', () {
    test('drops the underline AND the fill (the resolver seam owns the wash)',
        () {
      // #1045: the wash comes from the per-anchor resolver at bake time; a
      // registration-baked fill could not express verified alpha/suppression.
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
