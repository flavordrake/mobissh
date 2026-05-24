// UI preference providers (#518).
//
// `keybarVisibleProvider` controls whether the bottom keybar is rendered on
// the terminal screen. Default: true (matches the PWA where the key bar is
// visible whenever the keyboard is up). The toggle lives inside the session
// menu; the setting persists across launches via SharedPreferences.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key. Matches the keep-alive naming style.
const String keybarVisiblePrefKey = 'mobissh.ui.keybarVisible';

/// Default to visible — parity with the PWA default.
const bool keybarVisibleDefault = true;

/// User toggle for the bottom keybar. Synchronous value (defaulted to
/// [keybarVisibleDefault] while we load preferences) so the UI doesn't need
/// a loading state.
class KeybarVisibleNotifier extends StateNotifier<bool> {
  KeybarVisibleNotifier({Future<SharedPreferences>? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance(),
        super(keybarVisibleDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getBool(keybarVisiblePrefKey);
      if (stored != null && stored != state) state = stored;
    } catch (_) {
      // SharedPreferences may be unavailable in tests without bindings; keep
      // the default in that case.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await _prefs;
      await prefs.setBool(keybarVisiblePrefKey, value);
    } catch (_) {
      // best-effort persistence
    }
  }

  void toggle() => set(!state);
}

final keybarVisibleProvider =
    StateNotifierProvider<KeybarVisibleNotifier, bool>((ref) {
  return KeybarVisibleNotifier();
});
