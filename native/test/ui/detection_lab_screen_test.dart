// #1031 slice 2 — the Detection Lab UI: root cards + per-pattern detail pages
// over the merged slice-1 store/resolver and the #1030 shared color picker.
//
// Locks the IA review's binding changes:
//   1. NO dead controls — url/command detail pages show ONE preview state and
//      ONE intensity slider (verified/active controls are paths-only, per
//      detectionPatternHasActiveState).
//   2. Preview labels its theme source (front session accent, fallback default).
//   3. Preview is PINNED (outside the scrollable controls list).
//   4. Destructive resets sit at the BOTTOM (root: lab-wide; detail:
//      per-pattern), both behind confirm dialogs.
//   6. Sliders' min/max ARE the legibility band (every position does something).
//
// Enable switches bind the SAME detectionSettingsProvider Settings uses (one
// bit, three surfaces). The URL card/detail writes id-level style to BOTH the
// `url` and `osc8` pattern ids (one user-facing type).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/detection_style_providers.dart';
import 'package:mobissh/ui/detection_lab_screen.dart';
import 'package:mobissh/ui/detection_style_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ProviderContainer> _pumpLab(WidgetTester tester,
    {Widget home = const DetectionLabScreen()}) async {
  // Tall viewport: the root list (3 cards + bottom reset) and the detail
  // controls all lay out hit-testable without scrolling.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ),
  );
  await _pumpFrames(tester);
  return container;
}

Widget _detail(String key) =>
    DetectionLabDetailScreen(spec: detectionLabPatternSpec(key));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('lab root', () {
    testWidgets('renders one card per registered pattern with a mini preview',
        (tester) async {
      await _pumpLab(tester);
      for (final key in const ['url', 'path', 'command']) {
        expect(find.byKey(ValueKey('lab-card-$key')), findsOneWidget,
            reason: 'card for $key');
        expect(find.byKey(ValueKey('lab-enable-$key')), findsOneWidget);
        expect(find.byKey(ValueKey('lab-preview-$key')), findsOneWidget,
            reason: 'mini live preview for $key');
      }
      expect(find.byKey(const ValueKey('lab-master-toggle')), findsOneWidget);
    });

    testWidgets('enable switches bind the EXISTING detection providers',
        (tester) async {
      final container = await _pumpLab(tester);
      expect(container.read(detectionSettingsProvider).url, isTrue);

      await tester.tap(find.byKey(const ValueKey('lab-enable-url')));
      await _pumpFrames(tester);
      expect(container.read(detectionSettingsProvider).url, isFalse,
          reason: 'the card switch flips the SAME provider Settings uses');

      // External change reflects back into the lab.
      await container.read(detectionSettingsProvider.notifier).setUrl(true);
      await _pumpFrames(tester);
      final sw = tester.widget<Switch>(
        find.byKey(const ValueKey('lab-enable-url')),
      );
      expect(sw.value, isTrue);
    });

    testWidgets('master OFF disables the per-pattern switches', (tester) async {
      final container = await _pumpLab(tester);
      await container
          .read(detectionSettingsProvider.notifier)
          .setEnabled(false);
      await _pumpFrames(tester);
      final sw = tester.widget<Switch>(
        find.byKey(const ValueKey('lab-enable-path')),
      );
      expect(sw.onChanged, isNull);
    });

    testWidgets('lab-wide reset sits at the BOTTOM, confirms, then clears '
        'every tuned override', (tester) async {
      final container = await _pumpLab(tester);
      final notifier = container.read(detectionStylesProvider.notifier);
      await notifier.setColorHex('url', '#e53935');
      await notifier.setInactiveIntensity('path', 1.4);
      await _pumpFrames(tester);

      // Review change 4: below the pattern cards, not in the thumb-prime zone.
      final resetY = tester
          .getTopLeft(find.byKey(const ValueKey('lab-reset-all-button')))
          .dy;
      final lastCardY = tester
          .getBottomLeft(find.byKey(const ValueKey('lab-card-command')))
          .dy;
      expect(resetY, greaterThan(lastCardY));

      await tester.tap(find.byKey(const ValueKey('lab-reset-all-button')));
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('lab-reset-all-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('lab-reset-all-confirm')));
      await _pumpFrames(tester);
      expect(container.read(detectionStylesProvider).isEmpty, isTrue);
    });

    testWidgets('tapping a card opens its detail page', (tester) async {
      await _pumpLab(tester);
      await tester.tap(find.byKey(const ValueKey('lab-card-tile-path')));
      await _pumpFrames(tester);
      expect(find.byType(DetectionLabDetailScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lab-detail-preview-detected')),
        findsOneWidget,
      );
    });
  });

  group('detail page — active-state gating (review change 1: no dead '
      'controls)', () {
    testWidgets('paths show BOTH states + both sliders', (tester) async {
      await _pumpLab(tester, home: _detail('path'));
      expect(
        find.byKey(const ValueKey('lab-detail-preview-detected')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lab-detail-preview-active')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lab-inactive-slider')), findsOneWidget);
      expect(find.byKey(const ValueKey('lab-active-slider')), findsOneWidget);
    });

    for (final key in const ['url', 'command']) {
      testWidgets('$key shows ONE state and NO active slider', (tester) async {
        await _pumpLab(tester, home: _detail(key));
        expect(
          find.byKey(const ValueKey('lab-detail-preview-detected')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('lab-detail-preview-active')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('lab-active-slider')), findsNothing);
      });
    }

    testWidgets('no disabled "coming" rows anywhere on a detail page',
        (tester) async {
      await _pumpLab(tester, home: _detail('url'));
      expect(find.textContaining('coming', findRichText: true), findsNothing);
    });
  });

  group('detail page — preview trust (review changes 2+3)', () {
    testWidgets('the preview block labels its theme source', (tester) async {
      await _pumpLab(tester, home: _detail('url'));
      expect(
        find.byKey(const ValueKey('lab-preview-source')),
        findsOneWidget,
      );
    });

    testWidgets('the preview is PINNED outside the scrolling controls list',
        (tester) async {
      await _pumpLab(tester, home: _detail('path'));
      final scrollable = find.byKey(const ValueKey('lab-detail-controls'));
      expect(scrollable, findsOneWidget);
      // The pinned preview must NOT be a descendant of the scrollable.
      expect(
        find.descendant(
          of: scrollable,
          matching: find.byKey(const ValueKey('lab-detail-preview-detected')),
        ),
        findsNothing,
        reason: 'preview scrolling away defeats the lab (review change 3)',
      );
    });

    testWidgets('a dark/light preview luminance toggle exists', (tester) async {
      await _pumpLab(tester, home: _detail('url'));
      expect(
        find.byKey(const ValueKey('lab-preview-luminance')),
        findsOneWidget,
      );
    });
  });

  group('detail page — color picker round-trip (#1030)', () {
    testWidgets('picking a preset writes the store for url AND osc8 '
        '(one user-facing type)', (tester) async {
      final container = await _pumpLab(tester, home: _detail('url'));
      await tester.tap(find.byKey(const ValueKey('lab-color-row')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('color-picker-panel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('color-picker-preset-#e53935')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await _pumpFrames(tester);

      final styles = container.read(detectionStylesProvider);
      expect(styles.of('url')!.colorHex, '#e53935');
      expect(styles.of('osc8')!.colorHex, '#e53935');
    });

    testWidgets('the clear action restores "use theme color" (null override)',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('url'));
      final notifier = container.read(detectionStylesProvider.notifier);
      await notifier.setColorHex('url', '#e53935');
      await notifier.setColorHex('osc8', '#e53935');
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('lab-color-row')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('color-picker-clear')));
      await _pumpFrames(tester);

      final styles = container.read(detectionStylesProvider);
      expect(styles.of('url'), isNull);
      expect(styles.of('osc8'), isNull);
    });
  });

  group('detail page — intensity sliders (review change 6)', () {
    testWidgets('slider min/max ARE the legibility band', (tester) async {
      await _pumpLab(tester, home: _detail('path'));
      final inactive = tester.widget<Slider>(
        find.byKey(const ValueKey('lab-inactive-slider')),
      );
      expect(inactive.min, kDetectionIntensityMin);
      expect(inactive.max, kDetectionIntensityMax);
      final active = tester.widget<Slider>(
        find.byKey(const ValueKey('lab-active-slider')),
      );
      expect(active.min, kDetectionIntensityMin);
      expect(active.max, kDetectionIntensityMax);
    });

    testWidgets('dragging the detected slider writes the store on release',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('url'));
      await tester.drag(
        find.byKey(const ValueKey('lab-inactive-slider')),
        const Offset(300, 0),
      );
      await _pumpFrames(tester);
      final url = container.read(detectionStylesProvider).of('url');
      expect(url?.inactiveIntensity, isNotNull);
      expect(url!.inactiveIntensity, greaterThan(1.0));
      // The osc8 twin carries the same tuning.
      expect(
        container.read(detectionStylesProvider).of('osc8')?.inactiveIntensity,
        url.inactiveIntensity,
      );
    });

    testWidgets('dragging detected past active PUSHES active (no inversion)',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('path'));
      // Drag detected to the far right (max).
      await tester.drag(
        find.byKey(const ValueKey('lab-inactive-slider')),
        const Offset(600, 0),
      );
      await _pumpFrames(tester);
      final style = container.read(detectionStylesProvider).of('path');
      expect(style, isNotNull);
      final inactive = style!.inactiveIntensity ?? 1.0;
      final active = style.activeIntensity ?? 1.0;
      expect(
        active,
        greaterThanOrEqualTo(inactive + kDetectionIntensityGap - 1e-9),
        reason: 'active must stay a visible margin above detected',
      );
    });
  });

  group('detail page — behavior knobs (real today only)', () {
    testWidgets('path: short-path verification toggle binds the store',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('path'));
      final toggle = find.byKey(const ValueKey('lab-verify-toggle'));
      expect(toggle, findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(toggle).value,
        isTrue,
        reason: 'default ON — the #990 shipped behavior',
      );
      await tester.tap(toggle);
      await _pumpFrames(tester);
      expect(
        container.read(detectionStylesProvider).of('path')!.verifyShortPaths,
        isFalse,
      );
    });

    testWidgets('url: NO behavior knobs render (nothing real today)',
        (tester) async {
      await _pumpLab(tester, home: _detail('url'));
      expect(find.byKey(const ValueKey('lab-verify-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('lab-lexicon-row')), findsNothing);
    });

    testWidgets('command: lexicon editor adds, removes, restores default',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('command'));
      // Seed a small stored lexicon so the chips are all on-screen.
      await container
          .read(detectionStylesProvider.notifier)
          .setLexicon('command', ['git', 'curl']);
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('lab-lexicon-row')));
      await _pumpFrames(tester);
      expect(find.byKey(const ValueKey('lab-lexicon-editor')), findsOneWidget);

      // Add a word.
      await tester.enterText(
        find.byKey(const ValueKey('lab-lexicon-add-field')),
        'frobnicate',
      );
      await tester.tap(find.byKey(const ValueKey('lab-lexicon-add-button')));
      await _pumpFrames(tester);
      expect(
        container.read(detectionStylesProvider).of('command')!.lexicon,
        containsAll(<String>['git', 'curl', 'frobnicate']),
      );

      // Remove one.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('lab-lexicon-chip-git')),
          matching: find.byIcon(Icons.cancel),
        ),
      );
      await _pumpFrames(tester);
      expect(
        container.read(detectionStylesProvider).of('command')!.lexicon,
        isNot(contains('git')),
      );

      // Restore the app-supplied default list (clears the override).
      await tester.tap(
        find.byKey(const ValueKey('lab-lexicon-restore-default')),
      );
      await _pumpFrames(tester);
      expect(
        container.read(detectionStylesProvider).of('command'),
        isNull,
        reason: 'restore-default drops the stored lexicon override',
      );
    });
  });

  group('detail page — per-pattern reset (review change 4)', () {
    testWidgets('resets THIS pattern (both url ids), leaves siblings',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('url'));
      final notifier = container.read(detectionStylesProvider.notifier);
      await notifier.setColorHex('url', '#e53935');
      await notifier.setColorHex('osc8', '#e53935');
      await notifier.setColorHex('path', '#43a047');
      await _pumpFrames(tester);

      await tester.tap(
        find.byKey(const ValueKey('lab-reset-pattern-button')),
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('lab-reset-pattern-dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('lab-reset-pattern-confirm')),
      );
      await _pumpFrames(tester);

      final styles = container.read(detectionStylesProvider);
      expect(styles.of('url'), isNull);
      expect(styles.of('osc8'), isNull);
      expect(styles.of('path')!.colorHex, '#43a047');
    });

    testWidgets('reset does NOT touch the enable bit (preference, not tuning)',
        (tester) async {
      final container = await _pumpLab(tester, home: _detail('url'));
      await container.read(detectionSettingsProvider.notifier).setUrl(false);
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const ValueKey('lab-reset-pattern-button')),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const ValueKey('lab-reset-pattern-confirm')),
      );
      await _pumpFrames(tester);
      expect(container.read(detectionSettingsProvider).url, isFalse);
    });
  });
}
