// Unit tests for the #913 persisted tmux-control-mode opt-in (Part D, epic #906).
//
// Locks the persisted-bool contract: default OFF, hydrate a stored true, set +
// persist, and a corrupt/non-bool stored value falling back to the default (a
// stale pref must never crash). Also asserts the notifier keeps the per-isolate
// `tmuxControlMode` global in sync (hydrate + set) — that global is what the
// proxy reads at connect time to populate `SshConnectCommand.controlMode`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settle() async {
  // Let the StateNotifier _hydrate Future resolve.
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Reset the per-isolate global so one test's ON state can't leak into the
    // next (the shipped default — and every other suite — assumes OFF).
    setTmuxControlModeForTest(false);
  });

  tearDown(() {
    setTmuxControlModeForTest(false);
  });

  group('TmuxControlModeNotifier', () {
    test('defaults OFF with no stored value', () async {
      expect(tmuxControlModeDefault, isFalse);
      final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, isFalse);
      // The global is seeded to the default immediately + after hydrate.
      expect(tmuxControlMode, isFalse);
    });

    test('hydrates a stored true value + syncs the global', () async {
      SharedPreferences.setMockInitialValues({
        tmuxControlModePrefKey: true,
      });
      final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, isTrue);
      expect(
        tmuxControlMode,
        isTrue,
        reason: 'hydrate must sync the global so the connect-time read carries '
            'the persisted ON choice',
      );
    });

    test('hydrate with a corrupt (non-bool) stored value keeps the default OFF',
        () async {
      // A legacy/garbage non-bool value: getBool returns null → default.
      SharedPreferences.setMockInitialValues({
        tmuxControlModePrefKey: 'yes',
      });
      final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, isFalse);
      expect(tmuxControlMode, isFalse);
    });

    test('set(true) updates state, persists, and flips the global', () async {
      final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.set(true);
      expect(n.state, isTrue);
      expect(tmuxControlMode, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(tmuxControlModePrefKey), isTrue);
    });

    test('set(false) persists OFF and clears the global', () async {
      SharedPreferences.setMockInitialValues({
        tmuxControlModePrefKey: true,
      });
      final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, isTrue);
      await n.set(false);
      expect(n.state, isFalse);
      expect(tmuxControlMode, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(tmuxControlModePrefKey), isFalse);
    });
  });
}
