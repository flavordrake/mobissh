// Persisted user setting for tmux control mode (`tmux -CC`) — Part D (#913).
//
// The control-mode arc (epic #906) is shipped flag-gated OFF: the parser (#907),
// render path (#909) and gestures (#911) all gate on the per-isolate
// `tmuxControlMode` global (tmux_control_mode_flag.dart), which defaults false so
// the proven screen-scrape path is the shipped default. A global default-ON flip
// would force `tmux -CC` on EVERY connect — breaking the test suite and any
// non-tmux host — so the rollout is a per-user OPT-IN instead.
//
// This is that opt-in: a persisted boolean (default false) the owner enables in
// Settings to validate control mode on real multi-window tmux. It follows the
// `terminal_backend.dart` / `ComposeBarVisibleNotifier` idiom: injectable prefs,
// synchronous default, best-effort hydrate/persist that never crashes when prefs
// are unavailable (widget tests without bindings), schema-tolerant `getBool`
// (a stale/corrupt non-bool value falls back to the default).
//
// HOW IT REACHES THE TASK ISOLATE: `SshSessionProxy.connect` (UI isolate) reads
// the per-isolate `tmuxControlMode` global at connect time and carries it across
// the gateway as `SshConnectCommand.controlMode` (Part C). This notifier keeps
// that global in sync with the PERSISTED value — it writes `tmuxControlMode` on
// hydrate and on every `set` — so the proxy's single connect-time read yields the
// user's saved choice. Centralising the read in the proxy (one site) avoids
// threading a flag through all three connect call sites, and preserves the
// gateway carrier contract. `setTmuxControlModeForTest` still flips the global
// directly, so the cc_render/cc_gestures integration tests force control mode ON
// regardless of this setting. Like the terminal-engine selector, the change takes
// effect on the NEXT connect / session (no live hot-swap).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../terminal/tmux_control_mode_flag.dart';

/// SharedPreferences key for the tmux-control-mode opt-in (#913). No key bumps —
/// schema tolerance lives in the value (see [_hydrate]), per code-style rules.
const String tmuxControlModePrefKey = 'mobissh.ui.tmuxControlMode';

/// Default OFF (#913). Control mode is experimental and forces `tmux -CC`, which
/// only works on hosts that have tmux — the owner opts in explicitly.
const bool tmuxControlModeDefault = false;

/// Persisted user opt-in for tmux control mode (#913). Synchronous default while
/// prefs hydrate so the first paint / a connect before hydrate is stable and OFF.
///
/// Keeps the per-isolate [tmuxControlMode] global in sync (writes it on hydrate +
/// set) so [SshSessionProxy.connect]'s connect-time global read carries the saved
/// choice across the gateway as `SshConnectCommand.controlMode`.
class TmuxControlModeNotifier extends StateNotifier<bool> {
  TmuxControlModeNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(tmuxControlModeDefault) {
    // Mirror the synchronous default into the global up front so a connect that
    // races hydrate sees a defined (OFF) value, never a stale prior-session one.
    tmuxControlMode = tmuxControlModeDefault;
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      // `getBool` returns null for a missing OR non-bool (corrupt/legacy) value,
      // so a stale schema falls back to the default — no crash, no key bump.
      final stored = prefs.getBool(tmuxControlModePrefKey);
      if (stored != null && stored != state) {
        state = stored;
      }
      // Sync the global to the resolved value (default or stored) so the proxy's
      // connect-time read reflects the persisted setting.
      tmuxControlMode = state;
    } catch (_) {
      // best-effort; keep default if prefs unavailable (tests). The constructor
      // already seeded the global with the default.
    }
  }

  /// Enable/disable control mode and persist it (best-effort). Updates the
  /// per-isolate global immediately so the NEXT connect carries it; takes effect
  /// on a new session / restart (does not hot-swap a live session — mirrors the
  /// terminal-engine selector).
  Future<void> set(bool value) async {
    state = value;
    tmuxControlMode = value;
    try {
      final prefs = await _prefs;
      await prefs.setBool(tmuxControlModePrefKey, value);
    } catch (_) {
      // best-effort persistence
    }
  }
}

/// Persisted global tmux-control-mode opt-in (#913, default OFF). Watch it on the
/// connect surface so it hydrates (and syncs the global) before the first connect.
final tmuxControlModeProvider =
    StateNotifierProvider<TmuxControlModeNotifier, bool>((ref) {
      return TmuxControlModeNotifier();
    });
