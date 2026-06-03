// Switchable terminal backend (#684, #582).
//
// MobiSSH renders session terminals with one of two widgets:
//   - `ghostty` (flterm, powered by libghostty-vt) — the DEFAULT (#725). flterm
//     has native touch drag-select + copy, which xterm.dart v4 lacks (#582).
//   - `xterm` (xterm.dart) — selectable fallback for anyone who prefers it or
//     hits a flterm device issue. The original production-proven path.
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
  /// xterm.dart `TerminalView` — selectable fallback, production-proven path.
  xterm,

  /// flterm `TerminalView` (libghostty-vt) — the default, native drag-select (#582, #725).
  ghostty,
}

/// SharedPreferences key for the selected terminal backend.
const String terminalBackendPrefKey = 'mobissh.ui.terminalBackend';

/// Default backend — `ghostty` (flterm, #725). flterm's native touch
/// drag-select + copy is the headline terminal UX, so it ships as the default.
/// `xterm` stays selectable in Settings → Terminal engine as the fallback for
/// anyone who prefers it or hits a flterm device issue.
const TerminalBackend terminalBackendDefault = TerminalBackend.ghostty;

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
