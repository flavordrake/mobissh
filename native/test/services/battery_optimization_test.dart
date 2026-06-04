// Battery-optimization exemption decision-logic tests (#738).
//
// The platform call (FlutterForegroundTask.isIgnoringBatteryOptimizations /
// requestIgnoreBatteryOptimization) and SharedPreferences are both injectable
// seams, so the prompt DECISION can be exercised without binding to method
// channels. We assert:
//   - prompt only when NOT exempt AND NOT already-asked
//   - the asked flag is persisted the first time we prompt
//   - a declined request is never re-prompted automatically (no nagging)
//   - already-exempt short-circuits with no request
//   - the explicit Settings request (requestNow) bypasses the asked gate
//   - platform errors degrade to `unavailable` rather than throwing.
//
// True Doze survival (lock the phone, wake, sessions still live) is DEVICE-ONLY
// and cannot be unit-tested — see the issue #738 acceptance + the TRACE.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/battery_optimization.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake platform seam that records calls and returns scripted values.
class _FakePlatform implements BatteryOptimizationPlatform {
  _FakePlatform({
    this.exempt = false,
    this.grantOnRequest = false,
    this.throwOnCheck = false,
    this.throwOnRequest = false,
  });

  bool exempt;
  bool grantOnRequest;
  bool throwOnCheck;
  bool throwOnRequest;

  int checkCount = 0;
  int requestCount = 0;

  @override
  Future<bool> get isIgnoringBatteryOptimizations async {
    checkCount += 1;
    if (throwOnCheck) throw StateError('no plugin');
    return exempt;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    requestCount += 1;
    if (throwOnRequest) throw StateError('no plugin');
    if (grantOnRequest) exempt = true;
    return grantOnRequest;
  }
}

Future<SharedPreferences> _prefsWith(Map<String, Object> values) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('maybePromptOnce', () {
    test('prompts when not exempt and not already asked', () async {
      final platform = _FakePlatform(exempt: false, grantOnRequest: true);
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: _prefsWith(<String, Object>{}),
      );

      final result = await controller.maybePromptOnce();

      expect(result.outcome, BatteryOptPromptOutcome.prompted);
      expect(result.granted, isTrue);
      expect(platform.requestCount, 1);
    });

    test('persists the asked flag the first time it prompts', () async {
      final platform = _FakePlatform(exempt: false, grantOnRequest: false);
      final prefs = await _prefsWith(<String, Object>{});
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: Future.value(prefs),
      );

      await controller.maybePromptOnce();

      expect(prefs.getBool(batteryOptAskedPrefKey), isTrue);
    });

    test('does NOT prompt when already exempt', () async {
      final platform = _FakePlatform(exempt: true);
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: _prefsWith(<String, Object>{}),
      );

      final result = await controller.maybePromptOnce();

      expect(result.outcome, BatteryOptPromptOutcome.alreadyExempt);
      expect(platform.requestCount, 0);
    });

    test('never re-nags after a declined request (asked flag set)', () async {
      final platform = _FakePlatform(exempt: false, grantOnRequest: false);
      final controller = BatteryOptimizationController(
        platform: platform,
        // asked flag already persisted from a prior declined prompt.
        prefs: _prefsWith(<String, Object>{batteryOptAskedPrefKey: true}),
      );

      final result = await controller.maybePromptOnce();

      expect(result.outcome, BatteryOptPromptOutcome.alreadyAsked);
      expect(platform.requestCount, 0);
    });

    test('a second call in the same session does not re-prompt', () async {
      final platform = _FakePlatform(exempt: false, grantOnRequest: false);
      final prefs = await _prefsWith(<String, Object>{});
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: Future.value(prefs),
      );

      final first = await controller.maybePromptOnce();
      final second = await controller.maybePromptOnce();

      expect(first.outcome, BatteryOptPromptOutcome.prompted);
      expect(second.outcome, BatteryOptPromptOutcome.alreadyAsked);
      expect(platform.requestCount, 1);
    });

    test('platform check error degrades to unavailable, no throw', () async {
      final platform = _FakePlatform(throwOnCheck: true);
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: _prefsWith(<String, Object>{}),
      );

      final result = await controller.maybePromptOnce();

      expect(result.outcome, BatteryOptPromptOutcome.unavailable);
      expect(platform.requestCount, 0);
    });

    test(
      'request error degrades to unavailable but asked flag is set',
      () async {
        // The asked flag is recorded BEFORE the request, so a thrown request
        // still counts as asked — we never retry-nag on a flaky platform call.
        final platform = _FakePlatform(exempt: false, throwOnRequest: true);
        final prefs = await _prefsWith(<String, Object>{});
        final controller = BatteryOptimizationController(
          platform: platform,
          prefs: Future.value(prefs),
        );

        final result = await controller.maybePromptOnce();

        expect(result.outcome, BatteryOptPromptOutcome.unavailable);
        expect(platform.requestCount, 1);
        expect(prefs.getBool(batteryOptAskedPrefKey), isTrue);
      },
    );
  });

  group('requestNow (explicit Settings affordance)', () {
    test('prompts even when the asked flag is already set', () async {
      final platform = _FakePlatform(exempt: false, grantOnRequest: true);
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: _prefsWith(<String, Object>{batteryOptAskedPrefKey: true}),
      );

      final result = await controller.requestNow();

      expect(result.outcome, BatteryOptPromptOutcome.prompted);
      expect(result.granted, isTrue);
      expect(platform.requestCount, 1);
    });

    test('short-circuits when already exempt', () async {
      final platform = _FakePlatform(exempt: true);
      final controller = BatteryOptimizationController(
        platform: platform,
        prefs: _prefsWith(<String, Object>{}),
      );

      final result = await controller.requestNow();

      expect(result.outcome, BatteryOptPromptOutcome.alreadyExempt);
      expect(platform.requestCount, 0);
    });
  });

  group('isExempt', () {
    test('reflects the platform value', () async {
      final controller = BatteryOptimizationController(
        platform: _FakePlatform(exempt: true),
        prefs: _prefsWith(<String, Object>{}),
      );
      expect(await controller.isExempt(), isTrue);
    });

    test('returns false on platform error rather than throwing', () async {
      final controller = BatteryOptimizationController(
        platform: _FakePlatform(throwOnCheck: true),
        prefs: _prefsWith(<String, Object>{}),
      );
      expect(await controller.isExempt(), isFalse);
    });
  });
}
