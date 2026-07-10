// #1031 slice 3 — custom-pattern provider behavior.
//
// The notifier hydrates the persisted list, mints ids ONCE on create (review
// change 5), keeps ids stable across edits, and AUTO-DISABLES a stored
// pattern whose regex no longer compiles (a hand-edited / corrupt source must
// degrade to a visible error state, never a crash or a wedged scanner).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/custom_patterns_providers.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<CustomPatternsNotifier> notifier() async {
    final n = CustomPatternsNotifier(
      store: CustomPatternsStore(prefs: await SharedPreferences.getInstance()),
    );
    await n.ready;
    return n;
  }

  test('create mints a custom.* id and enables the pattern', () async {
    final n = await notifier();
    final p = await n.create(
      name: 'Jira',
      source: r'[A-Z]{2,}-\d+',
      sampleLine: 'PROJ-1',
    );
    expect(p.id, startsWith(kCustomPatternIdPrefix));
    expect(n.state.single.enabled, isTrue);
  });

  test('updatePattern keeps the id across rename + regex edit', () async {
    final n = await notifier();
    final p = await n.create(name: 'Jira', source: r'\d+', sampleLine: '');
    await n.updatePattern(p.id, name: 'Renamed', source: r'\w+');
    expect(n.state.single.id, p.id);
    expect(n.state.single.name, 'Renamed');
    expect(n.state.single.source, r'\w+');
  });

  test('setEnabled + remove round-trip', () async {
    final n = await notifier();
    final p = await n.create(name: 'x', source: r'\d+', sampleLine: '');
    await n.setEnabled(p.id, false);
    expect(n.state.single.enabled, isFalse);
    await n.remove(p.id);
    expect(n.state, isEmpty);
  });

  test('hydrate AUTO-DISABLES a pattern whose stored regex no longer '
      'compiles (visible error state, never a crash)', () async {
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
          {
            'id': 'custom.fine',
            'name': 'fine',
            'source': r'\d+',
            'enabled': true,
            'ts': 6,
          },
        ],
      }),
    });
    final n = await notifier();
    final broken = n.state.firstWhere((p) => p.id == 'custom.broken');
    final fine = n.state.firstWhere((p) => p.id == 'custom.fine');
    expect(broken.enabled, isFalse, reason: 'auto-disabled on compile failure');
    expect(fine.enabled, isTrue);
  });
}
