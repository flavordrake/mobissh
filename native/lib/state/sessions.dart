// Multi-session collection (#511).
//
// Each connection lives in its own [SessionEntry] (controller + terminal +
// metadata). [SessionsNotifier] owns the map keyed by session id and tracks
// the active session.
//
// Session id format matches the PWA convention:
//   `${host}:${port}:${username}:${createdAtMs}`
// — see `src/modules/connection.ts` (line ~602). The `createdAtMs` suffix
// lets us differentiate two attempts to the same target across time while the
// `host:port:username` prefix powers dedup (issue #511 acceptance bullet 1).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';

/// One row in the session collection.
///
/// Holds the per-session controller + terminal model. Hidden sessions stay
/// alive in the widget tree (rendered through `IndexedStack`) so their
/// scrollback continues to fill in the background.
class SessionEntry {
  SessionEntry({
    required this.id,
    required this.host,
    required this.port,
    required this.username,
    required this.controller,
    required this.terminal,
  });

  final String id;
  final String host;
  final int port;
  final String username;
  final SshSessionController controller;
  final Terminal terminal;

  /// Dedup key — matches the prefix of [id] before `createdAt`.
  String get profileKey => '$host:$port:$username';

  /// Human label shown in the tab strip.
  String get label => '$username@$host:$port';
}

/// Immutable snapshot of the session collection. The notifier emits a fresh
/// copy on each mutation so Riverpod consumers re-render.
class SessionsState {
  const SessionsState({
    this.entries = const [],
    this.activeId,
  });

  /// Insertion-ordered list of entries (tab strip renders in this order).
  final List<SessionEntry> entries;

  /// Currently focused session id, or null when the collection is empty.
  final String? activeId;

  SessionEntry? get active {
    if (activeId == null) return null;
    for (final e in entries) {
      if (e.id == activeId) return e;
    }
    return null;
  }

  bool get isEmpty => entries.isEmpty;
  int get length => entries.length;

  SessionsState copyWith({
    List<SessionEntry>? entries,
    String? activeId,
    bool clearActiveId = false,
  }) {
    return SessionsState(
      entries: entries ?? this.entries,
      activeId: clearActiveId ? null : (activeId ?? this.activeId),
    );
  }
}

/// Factory injected for tests so they can substitute a controller whose
/// `connect()` is a no-op (no real network IO).
typedef SshSessionControllerFactory = SshSessionController Function();

SshSessionController _defaultControllerFactory() => SshSessionController();

/// Test seam — override in `ProviderScope.overrides` to inject a stub
/// factory. Production uses [_defaultControllerFactory] which creates a real
/// controller with the default socket opener.
final sshSessionControllerFactoryProvider =
    Provider<SshSessionControllerFactory>((ref) => _defaultControllerFactory);

/// Owns the multi-session collection. Mutations are synchronous; SSH connect
/// runs against the per-entry controller after `addOrActivate` returns.
class SessionsNotifier extends Notifier<SessionsState> {
  @override
  SessionsState build() => const SessionsState();

  /// Find an existing entry matching `host:port:username`.
  SessionEntry? findByProfile({
    required String host,
    required int port,
    required String username,
  }) {
    final key = '$host:$port:$username';
    for (final e in state.entries) {
      if (e.profileKey == key) return e;
    }
    return null;
  }

  /// Add a session for [params] or activate the existing entry that matches
  /// `host:port:username`. Returns the entry the caller should drive
  /// (`controller.connect(...)` for a fresh entry; no-op for an existing one).
  ///
  /// The caller invokes connect explicitly — keeping connect out of this
  /// method means the notifier stays pure-state and easy to test.
  SessionEntry addOrActivate(SshConnectParams params) {
    final existing = findByProfile(
      host: params.host,
      port: params.port,
      username: params.username,
    );
    if (existing != null) {
      state = state.copyWith(activeId: existing.id);
      return existing;
    }
    final controller = ref.read(sshSessionControllerFactoryProvider).call();
    final terminal = Terminal(maxLines: 5000);
    final id =
        '${params.host}:${params.port}:${params.username}:${DateTime.now().millisecondsSinceEpoch}';
    final entry = SessionEntry(
      id: id,
      host: params.host,
      port: params.port,
      username: params.username,
      controller: controller,
      terminal: terminal,
    );
    state = state.copyWith(
      entries: [...state.entries, entry],
      activeId: id,
    );
    return entry;
  }

  /// Make [id] the active session. No-op if not present.
  void setActive(String id) {
    for (final e in state.entries) {
      if (e.id == id) {
        state = state.copyWith(activeId: id);
        return;
      }
    }
  }

  /// Remove an entry and dispose its controller + terminal. If the active
  /// session was removed, pick the next remaining entry (or null) as active.
  void close(String id) {
    final remaining = <SessionEntry>[];
    SessionEntry? removed;
    for (final e in state.entries) {
      if (e.id == id) {
        removed = e;
      } else {
        remaining.add(e);
      }
    }
    if (removed == null) return;
    // Dispose async work (controller.disconnect/close) without blocking the
    // state update. Errors during teardown shouldn't wedge the UI.
    removed.controller.dispose();
    removed.terminal.onOutput = null;
    removed.terminal.onResize = null;

    String? newActive = state.activeId;
    if (state.activeId == id) {
      newActive = remaining.isEmpty ? null : remaining.first.id;
    }
    state = SessionsState(entries: remaining, activeId: newActive);
  }
}

/// Top-level provider for the session collection.
final sessionsProvider =
    NotifierProvider<SessionsNotifier, SessionsState>(SessionsNotifier.new);

/// Active session id (null when no sessions exist).
final activeSessionIdProvider = Provider<String?>((ref) {
  return ref.watch(sessionsProvider).activeId;
});

/// Active [SessionEntry] (null when no sessions exist).
final activeSessionEntryProvider = Provider<SessionEntry?>((ref) {
  return ref.watch(sessionsProvider).active;
});
