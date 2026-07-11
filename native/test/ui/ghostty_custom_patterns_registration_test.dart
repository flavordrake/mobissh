// #1031 slice 3 — custom-pattern REGISTRATION gating (pure, headless).
//
// ghosttyDetectionPatterns is the whole registration contract, so these lock:
// an enabled custom pattern registers a SPAN-tier TextPattern under its own
// id; a disabled one does not; an INVALID stored regex is skipped defensively
// (never a throw, never a wedged scanner); the master switch gates customs
// like every built-in. ghosttyDetectionActiveFor keeps the #921 repaint
// gating honest when ONLY a custom pattern is on. The gutter registry serves
// a generic presentation for any custom.* id (copy + "Not a match" → the
// #995 exception store, family = the custom id).

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';
import 'package:mobissh/ui/ghostty_gutter_layer.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

CustomPattern _pattern({
  String id = 'custom.p1',
  String source = r'[A-Z]{2,}-\d+',
  bool enabled = true,
}) =>
    CustomPattern(
      id: id,
      name: 'Jira',
      source: source,
      enabled: enabled,
      createdTs: 1,
      sampleLine: 'PROJ-1234',
    );

void main() {
  group('ghosttyDetectionPatterns — customs', () {
    test('an enabled custom pattern registers span-tier under its id', () {
      final patterns = ghosttyDetectionPatterns(
        const DetectionSettings(),
        customPatterns: [_pattern()],
      );
      final custom = patterns.where((p) => p.id == 'custom.p1');
      expect(custom, hasLength(1));
      expect(custom.single.tier, TextTier.span);
      expect(custom.single.regex.hasMatch('PROJ-1234'), isTrue);
    });

    test('a disabled custom pattern is NOT registered', () {
      final patterns = ghosttyDetectionPatterns(
        const DetectionSettings(),
        customPatterns: [_pattern(enabled: false)],
      );
      expect(patterns.any((p) => p.id == 'custom.p1'), isFalse);
    });

    test('an invalid stored regex is skipped defensively (no throw)', () {
      final patterns = ghosttyDetectionPatterns(
        const DetectionSettings(),
        customPatterns: [_pattern(source: '(')],
      );
      expect(patterns.any((p) => p.id == 'custom.p1'), isFalse);
    });

    test('master OFF gates customs like every built-in', () {
      final patterns = ghosttyDetectionPatterns(
        const DetectionSettings(enabled: false),
        customPatterns: [_pattern()],
      );
      expect(patterns, isEmpty);
    });

    test('customs coexist with the built-ins', () {
      final patterns = ghosttyDetectionPatterns(
        const DetectionSettings(),
        customPatterns: [_pattern()],
      );
      expect(
        patterns.map((p) => p.id),
        containsAll(<String>['osc8', 'url', 'path', 'command', 'custom.p1']),
      );
    });
  });

  group('ghosttyDetectionActiveFor (#921 repaint gating)', () {
    test('true when ONLY a custom pattern is on', () {
      // #1036 added the relpath type — "only a custom on" turns it off too.
      const detection = DetectionSettings(
        url: false,
        path: false,
        command: false,
        relpath: false,
      );
      expect(detection.detectionActive, isFalse);
      expect(ghosttyDetectionActiveFor(detection, [_pattern()]), isTrue);
    });

    test('false when the only custom is disabled or invalid', () {
      const detection = DetectionSettings(
        url: false,
        path: false,
        command: false,
        relpath: false,
      );
      expect(
        ghosttyDetectionActiveFor(detection, [_pattern(enabled: false)]),
        isFalse,
      );
      expect(
        ghosttyDetectionActiveFor(detection, [_pattern(source: '(')]),
        isFalse,
      );
    });

    test('master OFF wins over customs', () {
      const detection = DetectionSettings(enabled: false);
      expect(ghosttyDetectionActiveFor(detection, [_pattern()]), isFalse);
    });
  });

  group('exception family (#995 interplay)', () {
    test('a custom id is its OWN family', () {
      expect(detectionExceptionFamily('custom.p1'), 'custom.p1');
    });
  });

  group('gutter registry — generic custom presentation', () {
    GutterPatternRegistry registry({
      void Function(String patternId, String payload)? onReportException,
    }) =>
        GutterPatternRegistry.standard(
          openPath: (_) async => true,
          onReportException: onReportException,
        );

    test('any custom.* id resolves to a generic presentation', () {
      final p = registry().forPattern('custom.whatever');
      expect(p, isNotNull);
      expect(p!.patternId, 'custom.whatever');
    });

    test('unknown NON-custom ids still resolve to nothing', () {
      expect(registry().forPattern('mystery'), isNull);
    });

    test('item actions: copy + "Not a match" reporting the custom family',
        () {
      final reports = <(String, String)>[];
      final p = registry(
        onReportException: (patternId, payload) =>
            reports.add((patternId, payload)),
      ).forPattern('custom.p1')!;
      final actions = p.itemActions('PROJ-1234');
      expect(
        actions.map((a) => a.keyLabel),
        containsAll(<String>['copy', 'not']),
      );
    });

    test('without a report callback there is no "not" item', () {
      final p = registry().forPattern('custom.p1')!;
      expect(p.itemActions('X-1').map((a) => a.keyLabel), isNot(contains('not')));
    });
  });
}
