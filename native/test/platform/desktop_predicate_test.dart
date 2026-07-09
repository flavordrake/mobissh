// Platform-predicate truth table (#1026 iOS gating slice).
//
// `kIsDesktop` means "desktop UX / desktop OS" (macOS / Linux / Windows).
// `kUsesInProcessHost` means "the SSH SessionHost runs IN-PROCESS — no Android
// foreground service, no task isolate". Those are NOT the same set: iOS has no
// FGS equivalent, so it must use the in-process host (sessions drop on
// background and revive on foreground via the existing resume machinery) while
// remaining non-desktop for UX purposes.
//
// The real `Platform` is unreadable-per-OS from a test host, so the predicates
// resolve the OS through the injectable `debugOperatingSystemOverride` seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/platform/desktop.dart';

void main() {
  tearDown(() {
    debugOperatingSystemOverride = null;
  });

  group('kIsDesktop truth table', () {
    for (final os in ['macos', 'linux', 'windows']) {
      test('$os → desktop', () {
        debugOperatingSystemOverride = os;
        expect(kIsDesktop, isTrue);
      });
    }
    for (final os in ['android', 'ios']) {
      test('$os → NOT desktop', () {
        debugOperatingSystemOverride = os;
        expect(kIsDesktop, isFalse);
      });
    }
  });

  group('kUsesInProcessHost truth table (#1026)', () {
    for (final os in ['macos', 'linux', 'windows', 'ios']) {
      test('$os → in-process host (no FGS)', () {
        debugOperatingSystemOverride = os;
        expect(kUsesInProcessHost, isTrue);
      });
    }
    test('android → FGT task-isolate host', () {
      debugOperatingSystemOverride = 'android';
      expect(kUsesInProcessHost, isFalse);
    });
  });
}
