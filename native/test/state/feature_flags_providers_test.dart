// #1257: the single "Show experimental settings" flag. One SharedPreferences
// key holding a versioned JSON value (the version lives in the value, never the
// key); corrupt or unknown-version data falls back to the default, no crash.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/feature_flags_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<FeatureFlagsNotifier> _hydrated(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final n = FeatureFlagsNotifier(prefs: SharedPreferences.getInstance());
  // Hydrate is async; let it settle.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('key and default', () async {
    expect(featureFlagsPrefKey, 'mobissh.ui.featureFlags');
    final n = await _hydrated(<String, Object>{});
    expect(n.state.showExperimental, isFalse);
  });

  test('round-trips through the versioned JSON value', () async {
    final n = await _hydrated(<String, Object>{});
    await n.setShowExperimental(true);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(featureFlagsPrefKey);
    expect(jsonDecode(raw!), {'v': 1, 'showExperimental': true});

    final again = await _hydrated(<String, Object>{
      featureFlagsPrefKey: raw,
    });
    expect(again.state.showExperimental, isTrue);
  });

  test('corrupt JSON falls back to the default without throwing', () async {
    final n = await _hydrated(<String, Object>{
      featureFlagsPrefKey: '{not json',
    });
    expect(n.state.showExperimental, isFalse);
  });

  test('a non-object or wrong-typed value falls back to the default', () async {
    expect(FeatureFlags.fromJsonString('[1,2]').showExperimental, isFalse);
    expect(
      FeatureFlags.fromJsonString('{"v":1,"showExperimental":"yes"}')
          .showExperimental,
      isFalse,
    );
    expect(FeatureFlags.fromJsonString(null).showExperimental, isFalse);
  });

  test('an unknown schema version falls back to the default', () async {
    final n = await _hydrated(<String, Object>{
      featureFlagsPrefKey: '{"v":99,"showExperimental":true}',
    });
    expect(n.state.showExperimental, isFalse);
  });

  test('reset restores the default and persists it', () async {
    final n = await _hydrated(<String, Object>{
      featureFlagsPrefKey: '{"v":1,"showExperimental":true}',
    });
    expect(n.state.showExperimental, isTrue);
    await n.reset();
    expect(n.state.showExperimental, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString(featureFlagsPrefKey)!),
      {'v': 1, 'showExperimental': false},
    );
  });
}
