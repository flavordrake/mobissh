// Switchable terminal backend (#684, #582).
//
// MobiSSH renders session terminals with one of two widgets:
//   - `xterm` (xterm.dart) — the DEFAULT and the only production-proven path.
//   - `ghostty` (flterm, powered by libghostty-vt) — opt-in. flterm has native
//     touch drag-select + copy, which xterm.dart v4 lacks (#582). It's offered
//     so the owner can device-test drag-select on real sessions.
//
// The choice is a persisted GLOBAL preference (NOT per-session): it picks the
// rendering engine for every new session terminal. It is read at terminal-view
// BUILD time, so switching it takes effect on a RESTART (or a fresh session) —
// we deliberately do not hot-swap a live session's terminal widget. Settings
// surfaces a restart note next to the selector.
//
// Persisted via shared_preferences, mirroring `ComposeBarVisibleNotifier`
// (ui_prefs_providers.dart): synchronous default so the first paint is stable,
// best-effort hydrate/persist that never crashes when prefs are unavailable
// (widget tests without bindings).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The terminal rendering engine for session terminals (#684).
enum TerminalBackend {
  /// xterm.dart `TerminalView` — the default, production-proven path.
  xterm,

  /// flterm `TerminalView` (libghostty-vt) — opt-in, native drag-select (#582).
  ghostty,
}

/// SharedPreferences key for the selected terminal backend.
const String terminalBackendPrefKey = 'mobissh.ui.terminalBackend';

/// Default backend — `xterm`. The switch must ship safely even if flterm has
/// device issues: the owner simply won't flip it.
const TerminalBackend terminalBackendDefault = TerminalBackend.xterm;

/// Resolve a stored backend id (the enum `name`) to a [TerminalBackend],
/// falling back to [terminalBackendDefault] for null/unknown values so a stale
/// or corrupt pref never crashes the terminal.
TerminalBackend terminalBackendFromId(String? id) {
  if (id == null) return terminalBackendDefault;
  for (final b in TerminalBackend.values) {
    if (b.name == id) return b;
  }
  return terminalBackendDefault;
}

/// Persisted global terminal-backend selection (#684). Synchronous value
/// (defaulted while prefs hydrate) so the terminal can render immediately.
class TerminalBackendNotifier extends StateNotifier<TerminalBackend> {
  TerminalBackendNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(terminalBackendDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getString(terminalBackendPrefKey);
      if (stored != null) {
        final parsed = terminalBackendFromId(stored);
        if (parsed != state) state = parsed;
      }
    } catch (_) {
      // best-effort; keep default if prefs unavailable (tests).
    }
  }

  /// Select [value] and persist it (best-effort). Takes effect at the next
  /// terminal-view build (restart / new session); does not hot-swap live views.
  Future<void> set(TerminalBackend value) async {
    state = value;
    try {
      final prefs = await _prefs;
      await prefs.setString(terminalBackendPrefKey, value.name);
    } catch (_) {
      // best-effort persistence
    }
  }
}

final terminalBackendProvider =
    StateNotifierProvider<TerminalBackendNotifier, TerminalBackend>((ref) {
      return TerminalBackendNotifier();
    });
