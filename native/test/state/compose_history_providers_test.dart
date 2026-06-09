// Per-session compose history ring (#797) — PWA parity with src/modules/ime.ts
// `_commitHistory`.
//
// These tests assert the ring SEMANTICS (dedup, cap, empty-skip) and ISOLATION
// (memory: feedback_feature_scoping_and_isolation_tests): pushing to one session
// never changes another. The browse cursor is the compose bar's job (covered in
// the widget test); here we only verify the durable list.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/compose_history_providers.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('compose history ring', () {
    test('push records text, historyOf returns it oldest-first', () {
      final c = makeContainer();
      final notifier = c.read(composeHistoryProvider.notifier);
      notifier.push('s1', 'a');
      notifier.push('s1', 'b');
      notifier.push('s1', 'c');
      expect(notifier.historyOf('s1'), ['a', 'b', 'c']);
    });

    test('empty text is not recorded (PWA: _recordHistory skips falsy)', () {
      final c = makeContainer();
      final notifier = c.read(composeHistoryProvider.notifier);
      notifier.push('s1', '');
      expect(notifier.historyOf('s1'), isEmpty);
    });

    test('consecutive identical entries are de-duplicated', () {
      final c = makeContainer();
      final notifier = c.read(composeHistoryProvider.notifier);
      notifier.push('s1', 'ls');
      notifier.push('s1', 'ls');
      expect(notifier.historyOf('s1'), ['ls']);
      // Non-consecutive duplicate is kept (matches PWA — only consecutive dedup).
      notifier.push('s1', 'pwd');
      notifier.push('s1', 'ls');
      expect(notifier.historyOf('s1'), ['ls', 'pwd', 'ls']);
    });

    test('ring caps at kComposeHistoryMax, evicting the oldest', () {
      final c = makeContainer();
      final notifier = c.read(composeHistoryProvider.notifier);
      for (var i = 0; i < kComposeHistoryMax + 5; i++) {
        notifier.push('s1', 'cmd$i');
      }
      final h = notifier.historyOf('s1');
      expect(h.length, kComposeHistoryMax);
      // Oldest 5 evicted; newest retained.
      expect(h.first, 'cmd5');
      expect(h.last, 'cmd${kComposeHistoryMax + 4}');
    });

    test('unknown session has empty history', () {
      final c = makeContainer();
      expect(
        c.read(composeHistoryProvider.notifier).historyOf('nope'),
        isEmpty,
      );
    });

    test('per-session isolation: pushing s1 does not leak into s2', () {
      final c = makeContainer();
      final notifier = c.read(composeHistoryProvider.notifier);
      notifier.push('s1', 'one');
      notifier.push('s1', 'two');
      notifier.push('s2', 'alpha');
      expect(notifier.historyOf('s1'), ['one', 'two']);
      expect(notifier.historyOf('s2'), ['alpha']);
    });
  });

  group('compose draft slot (#842)', () {
    test('set stashes a draft, draftOf returns it', () {
      final c = makeContainer();
      final notifier = c.read(composeDraftProvider.notifier);
      notifier.set('s1', 'in progress text');
      expect(notifier.draftOf('s1'), 'in progress text');
    });

    test('unknown session has no draft (null)', () {
      final c = makeContainer();
      expect(c.read(composeDraftProvider.notifier).draftOf('nope'), isNull);
    });

    test('set with empty text clears the slot (no blank draft)', () {
      final c = makeContainer();
      final notifier = c.read(composeDraftProvider.notifier);
      notifier.set('s1', 'something');
      notifier.set('s1', '');
      expect(notifier.draftOf('s1'), isNull);
    });

    test('set with whitespace-only text clears the slot', () {
      final c = makeContainer();
      final notifier = c.read(composeDraftProvider.notifier);
      notifier.set('s1', 'something');
      notifier.set('s1', '   \n\t ');
      expect(notifier.draftOf('s1'), isNull);
    });

    test('clear drops the draft', () {
      final c = makeContainer();
      final notifier = c.read(composeDraftProvider.notifier);
      notifier.set('s1', 'draft');
      notifier.clear('s1');
      expect(notifier.draftOf('s1'), isNull);
    });

    test('per-session isolation: a draft in s1 never leaks into s2', () {
      final c = makeContainer();
      final notifier = c.read(composeDraftProvider.notifier);
      notifier.set('s1', 'one');
      notifier.set('s2', 'two');
      notifier.clear('s1');
      expect(notifier.draftOf('s1'), isNull);
      expect(notifier.draftOf('s2'), 'two');
    });
  });
}
