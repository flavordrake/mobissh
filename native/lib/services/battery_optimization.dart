// Battery-optimization exemption flow (#738).
//
// Android Doze aggressively defers an app's network and freezes its in-isolate
// timers on extended sleep UNLESS the user has excluded the app from battery
// optimization. The keep-alive foreground service (keepalive_task.dart) holds a
// CPU wake lock + a Wi-Fi lock while sessions are live, but Doze can still
// defer the process on long sleeps without this exemption. Requesting it lets
// the FGS actually keep the SSH socket warm so ordinary screen-off sleeps do
// NOT drop live sessions.
//
// This module is the DECISION layer: it decides whether to prompt the user
// (only when NOT already exempt AND we have not already asked), records that we
// asked (so we never re-nag after a decline), and invokes the platform request.
// The platform call + prefs are behind injectable seams so the decision logic
// is unit-testable without binding to method channels (#738 TDD).

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/connect_trace.dart';

/// Thin seam over the `FlutterForegroundTask` battery-optimization statics so
/// tests can inject a fake without binding to platform method channels.
abstract class BatteryOptimizationPlatform {
  /// Whether the app is currently excluded from battery optimization.
  Future<bool> get isIgnoringBatteryOptimizations;

  /// Prompt the OS to exclude the app from battery optimization. Returns true
  /// if the app is exempt after the request resolves.
  Future<bool> requestIgnoreBatteryOptimization();
}

/// Production seam backed by the real plugin statics.
class FftBatteryOptimizationPlatform implements BatteryOptimizationPlatform {
  const FftBatteryOptimizationPlatform();

  @override
  Future<bool> get isIgnoringBatteryOptimizations =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;

  @override
  Future<bool> requestIgnoreBatteryOptimization() =>
      FlutterForegroundTask.requestIgnoreBatteryOptimization();
}

/// SharedPreferences key recording that we have asked the user once. Persisted
/// so a declined request is never re-prompted automatically (#738: no nagging).
const String batteryOptAskedPrefKey = 'mobissh.batteryOpt.asked';

/// The outcome of an auto-prompt decision/attempt.
enum BatteryOptPromptOutcome {
  /// Already exempt — nothing to do.
  alreadyExempt,

  /// We already asked once before (and weren't exempt) — do not re-nag.
  alreadyAsked,

  /// We prompted the user this time. [granted] reflects the result.
  prompted,

  /// The platform call failed (e.g. plugin missing on desktop/test host).
  unavailable,
}

/// The result of [BatteryOptimizationController.maybePromptOnce].
class BatteryOptPromptResult {
  const BatteryOptPromptResult(this.outcome, {this.granted = false});

  final BatteryOptPromptOutcome outcome;

  /// Whether the app ended up exempt (only meaningful when the user was
  /// actually prompted this time).
  final bool granted;

  bool get didPrompt => outcome == BatteryOptPromptOutcome.prompted;
}

/// Owns the battery-optimization exemption decision (#738).
///
/// `maybePromptOnce` is the auto-prompt entry point: it prompts ONLY when the
/// app is not already exempt AND we have not already asked once. It records the
/// asked flag the first time it prompts, so a declined request is never
/// re-shown automatically. `requestNow` is the explicit Settings affordance
/// (always honored, no asked-flag gate) for a user who wants to re-grant after
/// declining.
class BatteryOptimizationController {
  BatteryOptimizationController({
    BatteryOptimizationPlatform? platform,
    Future<SharedPreferences>? prefs,
  }) : _platform = platform ?? const FftBatteryOptimizationPlatform(),
       _prefs = prefs ?? SharedPreferences.getInstance();

  final BatteryOptimizationPlatform _platform;
  final Future<SharedPreferences> _prefs;

  /// Auto-prompt at a sensible moment (e.g. first successful connect). Prompts
  /// at most once across the app's lifetime: if the user declines, the asked
  /// flag stays set and this returns [BatteryOptPromptOutcome.alreadyAsked]
  /// thereafter. Returns [BatteryOptPromptOutcome.alreadyExempt] when no prompt
  /// is needed.
  Future<BatteryOptPromptResult> maybePromptOnce() async {
    bool exempt;
    try {
      exempt = await _platform.isIgnoringBatteryOptimizations;
    } catch (e) {
      ctrace('battery-opt', 'isIgnoring check failed — $e');
      return const BatteryOptPromptResult(BatteryOptPromptOutcome.unavailable);
    }
    if (exempt) {
      return const BatteryOptPromptResult(
        BatteryOptPromptOutcome.alreadyExempt,
      );
    }
    if (await _hasAsked()) {
      return const BatteryOptPromptResult(BatteryOptPromptOutcome.alreadyAsked);
    }
    // Record that we've asked BEFORE awaiting the prompt so a crash/kill during
    // the OS dialog still counts as "asked" — we never want to nag on a loop.
    await _markAsked();
    try {
      final granted = await _platform.requestIgnoreBatteryOptimization();
      ctrace('battery-opt', 'requested exemption → granted=$granted');
      return BatteryOptPromptResult(
        BatteryOptPromptOutcome.prompted,
        granted: granted,
      );
    } catch (e) {
      ctrace('battery-opt', 'request failed — $e');
      return const BatteryOptPromptResult(BatteryOptPromptOutcome.unavailable);
    }
  }

  /// Explicit user-initiated request (Settings affordance). Always prompts when
  /// not already exempt, regardless of the asked flag — a user who declined and
  /// changed their mind can re-grant from Settings. Records the asked flag too.
  Future<BatteryOptPromptResult> requestNow() async {
    bool exempt;
    try {
      exempt = await _platform.isIgnoringBatteryOptimizations;
    } catch (e) {
      ctrace('battery-opt', 'isIgnoring check failed — $e');
      return const BatteryOptPromptResult(BatteryOptPromptOutcome.unavailable);
    }
    if (exempt) {
      return const BatteryOptPromptResult(
        BatteryOptPromptOutcome.alreadyExempt,
      );
    }
    await _markAsked();
    try {
      final granted = await _platform.requestIgnoreBatteryOptimization();
      ctrace('battery-opt', 'requestNow → granted=$granted');
      return BatteryOptPromptResult(
        BatteryOptPromptOutcome.prompted,
        granted: granted,
      );
    } catch (e) {
      ctrace('battery-opt', 'requestNow failed — $e');
      return const BatteryOptPromptResult(BatteryOptPromptOutcome.unavailable);
    }
  }

  /// Whether the app is currently exempt. Surfaces to the Settings UI so it can
  /// show the live state. Returns false on any platform error.
  Future<bool> isExempt() async {
    try {
      return await _platform.isIgnoringBatteryOptimizations;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasAsked() async {
    try {
      final prefs = await _prefs;
      return prefs.getBool(batteryOptAskedPrefKey) ?? false;
    } catch (_) {
      // Without bindings (test host) treat as not-asked so explicit tests that
      // inject prefs drive the flag; production always has bindings.
      return false;
    }
  }

  Future<void> _markAsked() async {
    try {
      final prefs = await _prefs;
      await prefs.setBool(batteryOptAskedPrefKey, true);
    } catch (_) {
      // best-effort persistence
    }
  }
}
