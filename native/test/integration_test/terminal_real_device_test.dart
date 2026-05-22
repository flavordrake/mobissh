// Real-device acceptance stubs for Phase 2.A terminal interaction.
//
// The cardinal rule from `docs/native-rewrite-lessons-from-pwa.md`: every
// phase that touches a failure mode "only real-device-visible" must commit
// a real-device test stub at the time of the phase's PR. Phase 6 fills
// these in once the emulator is wired through `flutter_driver` /
// `integration_test`.
//
// For Phase 2.A the failure modes worth catching on hardware are:
//   - Typing into the terminal and seeing the bytes echo back
//   - Soft keyboard appearing when the terminal gains focus
//   - Soft keyboard dismissing on back-button without breaking the session
//   - Orientation rotation preserving the buffer + reflowing correctly
//
// Each stub is a no-op until Phase 6 — the names + `@Skip` annotations are
// what document the contract.

@Tags(['integration', 'real_device'])
@Skip('Phase 6: enable when emulator + flutter_driver are wired')
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Terminal real-device acceptance (Phase 2.A surfaces)', () {
    testWidgets('type "echo hi\\n" — see "hi" on the next line', (tester) async {
      // Phase 6: drive the emulator keyboard, assert echoed output appears
      // in the terminal buffer.
    });

    testWidgets('soft keyboard appears when terminal gains focus',
        (tester) async {
      // Phase 6: tap on the terminal and verify Android's IME surfaces.
    });

    testWidgets('back-button dismisses soft keyboard without closing session',
        (tester) async {
      // Phase 6: dismiss via system back, assert the SSH session stays
      // `connected` and the terminal still accepts input.
    });

    testWidgets('orientation rotation preserves buffer + reflows PTY',
        (tester) async {
      // Phase 6: rotate landscape ↔ portrait, assert the buffer contents
      // survive and the PTY resize reaches the remote shell.
    });
  });
}
