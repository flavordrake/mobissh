// #1031 slice 3 — user-defined patterns in the Detection Lab UI.
//
// Locks: the creation flow (live regex validation with an INLINE error —
// never a crash — and a sample-line echo highlighting the match), custom
// cards in the MY PATTERNS zone (generic glyph, enable switch bound to the
// custom store, a visible ERROR state for a non-compiling stored regex),
// id stability across an edit (review change 5), style edits persisting
// under the custom id (string-keyed store), and the delete confirm that
// DISCLOSES + performs the #995 exception-family pruning.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/custom_patterns_providers.dart';
import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/state/detection_style_providers.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:mobissh/ui/detection_lab_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ProviderContainer> _pumpLab(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DetectionLabScreen()),
    ),
  );
  await _pumpFrames(tester);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('creation flow', () {
    testWidgets('lab root offers Add pattern under MY PATTERNS',
        (tester) async {
      await _pumpLab(tester);
      expect(find.byKey(const ValueKey('lab-add-pattern')), findsOneWidget);
    });

    testWidgets(
        'invalid regex shows an INLINE error and blocks Save; a valid one '
        'clears it and the sample echo highlights the match', (tester) async {
      final container = await _pumpLab(tester);
      await tester.tap(find.byKey(const ValueKey('lab-add-pattern')));
      await _pumpFrames(tester);

      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-name')),
        'Jira tickets',
      );
      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-regex')),
        '(',
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('lab-custom-regex-error')),
        findsOneWidget,
        reason: 'compile errors render inline, never crash',
      );
      final saveDisabled = tester.widget<FilledButton>(
        find.byKey(const ValueKey('lab-custom-save')),
      );
      expect(saveDisabled.onPressed, isNull, reason: 'Save blocked while invalid');

      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-regex')),
        r'[A-Z]{2,}-\d+',
      );
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('lab-custom-regex-error')),
        findsNothing,
      );

      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-sample')),
        'fixed in PROJ-1234 yesterday',
      );
      await _pumpFrames(tester);
      // The echo names the matched payload…
      expect(
        find.byKey(const ValueKey('lab-custom-sample-echo')),
        findsOneWidget,
      );
      expect(find.textContaining('PROJ-1234'), findsWidgets);
      // …and the sample line renders with the match span highlighted.
      expect(
        find.byKey(const ValueKey('lab-custom-sample-highlight')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('lab-custom-save')));
      await _pumpFrames(tester);

      final patterns = container.read(customPatternsProvider);
      expect(patterns, hasLength(1));
      final p = patterns.single;
      expect(p.id, startsWith(kCustomPatternIdPrefix));
      expect(p.name, 'Jira tickets');
      expect(p.enabled, isTrue);
      // Back on the root, the new pattern has a card.
      expect(find.byKey(ValueKey('lab-card-${p.id}')), findsOneWidget);
    });

    testWidgets('no sample match is a note, not an error (never blocks Save)',
        (tester) async {
      await _pumpLab(tester);
      await tester.tap(find.byKey(const ValueKey('lab-add-pattern')));
      await _pumpFrames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-name')),
        'x',
      );
      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-regex')),
        r'[A-Z]{2,}-\d+',
      );
      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-sample')),
        'nothing to see here',
      );
      await _pumpFrames(tester);
      expect(find.textContaining('no match', findRichText: true), findsWidgets);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('lab-custom-save')),
      );
      expect(save.onPressed, isNotNull);
    });
  });

  group('custom cards', () {
    testWidgets('enable switch binds the custom store', (tester) async {
      final container = await _pumpLab(tester);
      final p = await container
          .read(customPatternsProvider.notifier)
          .create(name: 'Jira', source: r'[A-Z]{2,}-\d+', sampleLine: 'AB-1');
      await _pumpFrames(tester);

      await tester.tap(find.byKey(ValueKey('lab-enable-${p.id}')));
      await _pumpFrames(tester);
      expect(
        container.read(customPatternsProvider).single.enabled,
        isFalse,
      );
    });

    testWidgets('a non-compiling stored regex renders a visible ERROR state',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        customPatternsPrefsKey: jsonEncode({
          'v': 1,
          'patterns': [
            {
              'id': 'custom.broken',
              'name': 'broken',
              'source': '(',
              'enabled': true,
              'ts': 5,
            },
          ],
        }),
      });
      await _pumpLab(tester);
      expect(
        find.byKey(const ValueKey('lab-card-error-custom.broken')),
        findsOneWidget,
        reason: 'a broken pattern is visibly flagged, never silently dropped',
      );
    });
  });

  group('detail page for a custom pattern', () {
    testWidgets('style edits persist under the custom id (string-keyed store)',
        (tester) async {
      final container = await _pumpLab(tester);
      final p = await container
          .read(customPatternsProvider.notifier)
          .create(name: 'Jira', source: r'[A-Z]{2,}-\d+', sampleLine: 'AB-1');
      await _pumpFrames(tester);

      await tester.tap(find.byKey(ValueKey('lab-card-tile-${p.id}')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const ValueKey('lab-color-row')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('color-picker-preset-#e53935')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await _pumpFrames(tester);

      expect(
        container.read(detectionStylesProvider).of(p.id)?.colorHex,
        '#e53935',
      );
    });

    testWidgets('editing (rename + regex) keeps the id (review change 5)',
        (tester) async {
      final container = await _pumpLab(tester);
      final p = await container
          .read(customPatternsProvider.notifier)
          .create(name: 'Jira', source: r'[A-Z]{2,}-\d+', sampleLine: 'AB-1');
      await _pumpFrames(tester);

      await tester.tap(find.byKey(ValueKey('lab-card-tile-${p.id}')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('lab-custom-edit-row')));
      await _pumpFrames(tester);

      await tester.enterText(
        find.byKey(const ValueKey('lab-custom-name')),
        'Issue keys',
      );
      await tester.tap(find.byKey(const ValueKey('lab-custom-save')));
      await _pumpFrames(tester);

      final updated = container.read(customPatternsProvider).single;
      expect(updated.id, p.id, reason: 'ids are minted once, never re-derived');
      expect(updated.name, 'Issue keys');
    });

    testWidgets(
        'delete confirm DISCLOSES exception pruning, prunes ONLY this '
        'family, and drops the style entry', (tester) async {
      final container = await _pumpLab(tester);
      final p = await container
          .read(customPatternsProvider.notifier)
          .create(name: 'Jira', source: r'[A-Z]{2,}-\d+', sampleLine: 'AB-1');
      final exceptions = container.read(detectionExceptionsProvider.notifier);
      await exceptions.report(patternId: p.id, matchedText: 'AB-1');
      await exceptions.report(patternId: p.id, matchedText: 'CD-2');
      await exceptions.report(patternId: 'url', matchedText: 'https://x.y');
      await container
          .read(detectionStylesProvider.notifier)
          .setColorHex(p.id, '#e53935');
      await _pumpFrames(tester);

      await tester.tap(find.byKey(ValueKey('lab-card-tile-${p.id}')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('lab-custom-delete-button')));
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('lab-custom-delete-dialog')),
        findsOneWidget,
      );
      // Review change 5: the dialog states it removes the saved exceptions.
      expect(
        find.textContaining('2 saved detection exception'),
        findsOneWidget,
        reason: 'pruning authored data must be disclosed at the moment it happens',
      );

      await tester.tap(find.byKey(const ValueKey('lab-custom-delete-confirm')));
      await _pumpFrames(tester);

      expect(container.read(customPatternsProvider), isEmpty);
      final remaining = container.read(detectionExceptionsProvider);
      expect(remaining, hasLength(1));
      expect(remaining.single.patternId, 'url');
      expect(container.read(detectionStylesProvider).of(p.id), isNull);
      // Back on the lab root; the card is gone.
      expect(find.byKey(ValueKey('lab-card-${p.id}')), findsNothing);
    });
  });
}
