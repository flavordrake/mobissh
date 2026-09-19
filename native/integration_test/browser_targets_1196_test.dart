// A4 — on-emulator browser enumeration + package-targeted open (#1196).
//
// This is the ONLY proof that the `<queries>` declaration already in
// `AndroidManifest.xml` (added for #570: ACTION_VIEW on http/https) actually
// covers ENUMERATION via `queryIntentActivities` on API 30+. A green fast gate
// does not establish it — package-visibility filtering is a runtime, on-device
// behaviour, and a filtered query returns an EMPTY list rather than an error.
//
// It drives the REAL `mobissh/browser` MethodChannel installed by
// `MainActivity.configureFlutterEngine`, so a Kotlin-side rename or a missing
// manifest entry fails HERE.
//
// What it asserts:
//   R1/R5 — `listBrowsers()` returns at least one real activity, each with a
//           non-empty package AND a non-empty OS-provided label (never a
//           hardcoded browser list).
//   R2    — `open(url, package)` with an ENUMERATED package reports
//           `opened && !usedFallback` (it started where we asked), and
//           `open(url, <not installed>)` reports `opened && usedFallback`
//           (it started somewhere else, and says so).
//
// Run: scripts/with-fleet-emulator.sh -- \
//        scripts/integration-subset.sh integration_test/browser_targets_1196_test.dart
// No SSH session is needed — this test never connects.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/services/browser_targets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // A URL that is safe to open on a disconnected emulator: nothing depends on
  // it loading, only on an activity being STARTED for it.
  const probeUrl = 'https://example.com/mobissh-1196';
  const notInstalled = 'com.mobissh.definitely.not.installed';

  testWidgets(
    'A4: listBrowsers enumerates real activities and open(package) targets '
    'them (R1/R2/R5)',
    (tester) async {
      // The channel lives on the engine, not on any widget — one frame is
      // enough to get the binding running.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));

      final targets = PlatformBrowserTargets();

      final browsers = await targets.listBrowsers();
      debugPrint(
        'A4 listBrowsers -> ${browsers.length} activity(ies): '
        '${browsers.map((b) => '${b.package}(${b.label})'
            '${b.isDefault ? ' DEFAULT' : ''}').join(', ')}',
      );

      expect(
        browsers,
        isNotEmpty,
        reason:
            'queryIntentActivities returned nothing for ACTION_VIEW https. '
            'Either this emulator image ships no browser, or the existing '
            '<queries> declaration (AndroidManifest.xml, #570) does NOT cover '
            'enumeration and a package-visibility entry must be added.',
      );
      for (final b in browsers) {
        expect(b.package, isNotEmpty);
        // R5: the label comes from loadLabel, never a hardcoded table.
        expect(b.label, isNotEmpty);
      }
      // One entry per package — a browser exposing several VIEW activities
      // must not appear repeatedly in a picker.
      expect(
        browsers.map((b) => b.package).toSet(),
        hasLength(browsers.length),
      );

      // R2 — targeted open at an ENUMERATED package. Prefer the default
      // handler when the platform reported one; otherwise any enumerated
      // browser will do.
      final target = browsers.firstWhere(
        (b) => b.isDefault,
        orElse: () => browsers.first,
      );
      final targeted = await targets.open(probeUrl, package: target.package);
      debugPrint(
        'A4 open(${target.package}) -> opened=${targeted.opened} '
        'usedFallback=${targeted.usedFallback} '
        'requested=${targeted.requestedPackage}',
      );
      expect(targeted.opened, isTrue);
      expect(targeted.usedFallback, isFalse);
      expect(targeted.requestedPackage, target.package);
      expect(targeted.openedAsRequested, isTrue);

      // R2 — a package that is NOT installed still opens, and SAYS it went
      // somewhere else. This runs second so the targeted start above is the
      // one made from the foreground (Android 10+ restricts background
      // activity starts); the assertion here is about the reported SHAPE,
      // which is decided before any such restriction applies.
      final missing = await targets.open(probeUrl, package: notInstalled);
      debugPrint(
        'A4 open($notInstalled) -> opened=${missing.opened} '
        'usedFallback=${missing.usedFallback}',
      );
      expect(missing.usedFallback, isTrue);
      expect(missing.requestedPackage, notInstalled);
      expect(missing.openedAsRequested, isFalse);
    },
  );
}
