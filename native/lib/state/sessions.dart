// Multi-session collection (#511).
//
// Each connection lives in its own [SessionEntry] (proxy + terminal +
// metadata). [SessionsNotifier] owns the map keyed by session id and tracks
// the active session.
//
// #533: the per-session `SshSessionController` instance was removed from
// SessionEntry. Sessions are now driven through [SshSessionProxy], which
// forwards commands across [TaskSshGateway] to a task-isolate-hosted
// `SessionHost`. The proxy's `output` stream is subscribed to each entry's
// `Terminal.write(...)` so PTY bytes flow UI-side without an in-UI
// `SSHClient`.
//
// Session id format matches the PWA convention:
//   `${host}:${port}:${username}:${createdAtMs}`
// — see `src/modules/connection.ts` (line ~602). The `createdAtMs` suffix
// lets us differentiate two attempts to the same target across time while the
// `host:port:username` prefix powers dedup (issue #511 acceptance bullet 1).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../diagnostics/connect_trace.dart';
import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../ui/terminal_mouse_handler.dart';
import 'keepalive_providers.dart';
import 'session_host_providers.dart';

/// One row in the session collection.
///
/// Holds the per-session proxy + terminal model. Hidden sessions stay
/// alive in the widget tree (rendered through `IndexedStack`) so their
/// scrollback continues to fill in the background.
class SessionEntry {
  SessionEntry({
    required this.id,
    required this.host,
    required this.port,
    required this.username,
    required this.proxy,
    required this.terminal,
    this.title,
  });

  final String id;
  final String host;
  final int port;
  final String username;

  /// UI-side proxy. Forwards commands (`connect`, `disconnect`, `sendInput`,
  /// `sendResize`) across [TaskSshGateway] and exposes a [data] snapshot +
  /// state [stream] mirrored from the task isolate's controller.
  final SshSessionProxy proxy;

  final Terminal terminal;

  /// Subscription bridging proxy PTY output → terminal write. Cancelled on
  /// close.
  StreamSubscription<Uint8List>? outputSub;

  /// Optional human-friendly title from the saved profile (PWA `profile.title`
  /// mirror). When set, it's preferred over `username@host:port` for display
  /// in the AppBar and session menu (#518).
  final String? title;

  /// Dedup key — matches the prefix of [id] before `createdAt`.
  String get profileKey => '$host:$port:$username';

  /// Human label shown in the AppBar / session menu. Prefer the saved
  /// profile title when present; fall back to `username@host:port` so
  /// ad-hoc connects still get a meaningful label (#518).
  String get label {
    final t = title;
    if (t != null && t.isNotEmpty) return t;
    return '$username@$host:$port';
  }
}

/// Immutable snapshot of the session collection. The notifier emits a fresh
/// copy on each mutation so Riverpod consumers re-render.
class SessionsState {
  const SessionsState({this.entries = const [], this.activeId});

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
/// `connect()` is a no-op (no real network IO). Retained for the task-side
/// `SessionHost`'s own factory wiring (#533) — UI-side construction no longer
/// uses this factory directly because sessions are driven through
/// [SshSessionProxy], not an in-UI controller.
typedef SshSessionControllerFactory = SshSessionController Function();

SshSessionController _defaultControllerFactory() => SshSessionController();

/// Test seam — override in `ProviderScope.overrides` to inject a stub
/// factory. Production uses [_defaultControllerFactory] which creates a real
/// controller with the default socket opener. Read by tests that wire a
/// `SessionHost` directly; UI consumers no longer touch it (#533).
final sshSessionControllerFactoryProvider =
    Provider<SshSessionControllerFactory>((ref) => _defaultControllerFactory);

/// Owns the multi-session collection. Mutations are synchronous; SSH connect
/// runs against the per-entry proxy after `addOrActivate` returns.
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
  /// (`proxy.connect(...)` for a fresh entry; no-op for an existing one).
  ///
  /// The optional [title] carries the saved profile's display title (#518).
  /// When supplied, it becomes the entry's `label` (AppBar + session menu).
  ///
  /// The caller invokes connect explicitly — keeping connect out of this
  /// method means the notifier stays pure-state and easy to test.
  SessionEntry addOrActivate(SshConnectParams params, {String? title}) {
    final existing = findByProfile(
      host: params.host,
      port: params.port,
      username: params.username,
    );
    if (existing != null) {
      // Re-activating an existing entry: make sure the foreground task isolate
      // is running before the caller re-drives `proxy.connect`. If the entry
      // lingered after a disconnect that stopped the service (last session
      // gone), the re-connect command would otherwise hit a dead isolate and
      // stick at idle (#564). ensureStarted is idempotent.
      unawaited(ref.read(keepaliveServiceStarterProvider)());
      state = state.copyWith(activeId: existing.id);
      return existing;
    }
    // #539: start the foreground task isolate NOW, before the caller dispatches
    // `proxy.connect(...)`. The task isolate is where the `SessionHost` turns
    // the connect command into a real `SSHClient.connect`; if it isn't running,
    // `sendDataToTask` drops the command and the session deadlocks at `idle`.
    // The UI-side gateway buffers commands until the task signals readiness, so
    // it's safe to start the service and connect without awaiting startup here.
    ctrace('ui.sessions', 'addOrActivate: new session → ensureStarted()');
    unawaited(ref.read(keepaliveServiceStarterProvider)());
    final id =
        '${params.host}:${params.port}:${params.username}:${DateTime.now().millisecondsSinceEpoch}';
    final gateway = ref.read(taskSshGatewayProvider);
    final proxy = SshSessionProxy(sessionId: id, gateway: gateway);
    ctrace('ui.sessions', 'created proxy + gateway for id=$id');
    final terminal = Terminal(maxLines: 5000);
    // #617: correct xterm-4.0.0's broken mouse-wheel SGR codes (it emits
    // button 68/69 instead of the canonical 64/65, which tmux/less ignore) so
    // a vertical touch-drag scrolls back through tmux history in the alternate
    // buffer. Surgical override — non-wheel events still use the library path.
    terminal.mouseHandler = const WheelFixMouseHandler();
    final entry = SessionEntry(
      id: id,
      host: params.host,
      port: params.port,
      username: params.username,
      proxy: proxy,
      terminal: terminal,
      title: title,
    );
    // Bridge proxy PTY output bytes → terminal.write. The subscription lives
    // on the entry so close() can cancel it. Malformed UTF-8 is replaced
    // rather than thrown (same policy as `SshShell.attach`).
    entry.outputSub = proxy.output.listen((bytes) {
      try {
        terminal.write(utf8.decode(bytes, allowMalformed: true));
      } catch (_) {
        // Defensive — Terminal.write should not throw on valid UTF-8, but
        // we never want a PTY byte to crash the session.
      }
    });
    // Wire terminal keystrokes back through the proxy to the task isolate.
    terminal.onOutput = (data) {
      proxy.sendInput(Uint8List.fromList(utf8.encode(data)));
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      proxy.sendResize(
        width,
        height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      );
    };
    state = state.copyWith(entries: [...state.entries, entry], activeId: id);
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

  /// Remove an entry and dispose its proxy + terminal. If the active
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
    // Dispose async work (proxy.disconnect/close) without blocking the
    // state update. Errors during teardown shouldn't wedge the UI.
    removed.outputSub?.cancel();
    removed.outputSub = null;
    removed.proxy.disconnect();
    unawaited(removed.proxy.dispose());
    removed.terminal.onOutput = null;
    removed.terminal.onResize = null;

    String? newActive = state.activeId;
    if (state.activeId == id) {
      newActive = remaining.isEmpty ? null : remaining.first.id;
    }
    state = SessionsState(entries: remaining, activeId: newActive);
  }
}

/// Fires a profile's "initial command" (#558) exactly once per session, when
/// the PTY shell first becomes ready — NOT on the bare `connected` STATE.
///
/// #619: gating on `connected` raced the shell open. The task-side shell
/// (`session_host.dart` `_ensureShell`) opens ASYNCHRONOUSLY after `connected`;
/// on a slow host (the owner's "ra-server") the command's `sendInput` reached
/// the task before `hosted.shell` was wired, so `_handleInput` dropped the
/// bytes into scrollback instead of the live shell — the command silently
/// vanished. Fast hosts opened the shell in time and the command landed,
/// explaining the per-host inconsistency. We now wait for the task's explicit
/// shell-ready signal ([SshSessionProxy.shellReady]) so stdin is provably
/// writable before we send.
///
/// The command is sent UI-side through the existing PTY input path
/// (`proxy.sendInput(utf8.encode(cmd + "\n"))`) — deliberately NOT through
/// `session_host.dart` / `ssh_session.dart`, which are owned by the parallel
/// SFTP work. Sending via the proxy is equivalent to the user typing the
/// command into the terminal and pressing Enter.
///
/// The once-only guard is the crux: the merged reconnect work (#551) re-opens
/// the shell on resume, which RE-EMITS shell-ready. Without a guard the command
/// would re-run on every background→resume / reconnect. We track which session
/// ids have already fired in [_fired]; a fired id never fires again for the
/// life of the runner, regardless of how many shell-ready ticks arrive.
class InitialCommandRunner {
  InitialCommandRunner();

  /// Session ids whose initial command has already been sent. Keyed by the
  /// full session id (`host:port:user:createdAtMs`) so two distinct connects
  /// to the same target each get their own one-shot.
  final Set<String> _fired = <String>{};

  final List<StreamSubscription<void>> _subs = [];

  /// True once the initial command has fired for [sessionId]. Test seam.
  bool hasFired(String sessionId) => _fired.contains(sessionId);

  /// Arm a one-shot: when [proxy] reports the PTY shell is ready (#619), send
  /// `command + "\n"` through its input path. No-op when [command] is empty
  /// or the session has already fired.
  ///
  /// Gating on shell-ready (not the bare `connected` state) is the fix for the
  /// slow-host drop: the task-side shell opens asynchronously after `connected`
  /// and `_handleInput` discards input that arrives before the shell is wired.
  ///
  /// If the proxy is ALREADY `connected` at arm time (e.g. a dedup re-activate
  /// of a live session whose shell is long since open), this does NOT arm — the
  /// command applies to a fresh connect only, matching the PWA's "run after the
  /// shell opens" behavior and the acceptance bullet "does not re-run on
  /// resume". A live session won't re-tick shell-ready unless it reconnects, and
  /// the one-shot guard would suppress that anyway, but skipping the arm keeps
  /// the intent explicit.
  void arm({
    required String sessionId,
    required SshSessionProxy proxy,
    required String? command,
  }) {
    final cmd = command?.trim() ?? '';
    if (cmd.isEmpty) return;
    if (_fired.contains(sessionId)) return;
    // Already connected when armed → this is a re-activate of a live session,
    // not a fresh connect. Don't fire (and don't arm a listener that would
    // fire on a future reconnect's shell re-open).
    if (proxy.data.state == SshSessionState.connected) return;

    late final StreamSubscription<void> sub;
    sub = proxy.shellReady.listen((_) {
      if (_fired.contains(sessionId)) return;
      _fired.add(sessionId);
      ctrace('ui.initcmd', 'firing initial command for sid=$sessionId');
      proxy.sendInput(Uint8List.fromList(utf8.encode('$cmd\n')));
      // One-shot: stop listening so a later reconnect shell re-open (#551)
      // can't re-trigger.
      sub.cancel();
      _subs.remove(sub);
    });
    _subs.add(sub);
  }

  /// Cancel any still-armed listeners. Fired runners have already self-
  /// cancelled; this cleans up sessions whose shell never opened.
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }
}

/// App-wide [InitialCommandRunner]. A single instance so the once-only guard
/// survives form rebuilds and the "New session" push/pop lifecycle — a new
/// `ConnectForm` state must not get a fresh guard set and re-fire.
final initialCommandRunnerProvider = Provider<InitialCommandRunner>((ref) {
  final runner = InitialCommandRunner();
  ref.onDispose(runner.dispose);
  return runner;
});

/// Top-level provider for the session collection.
final sessionsProvider = NotifierProvider<SessionsNotifier, SessionsState>(
  SessionsNotifier.new,
);

/// Active session id (null when no sessions exist).
final activeSessionIdProvider = Provider<String?>((ref) {
  return ref.watch(sessionsProvider).activeId;
});

/// Active [SessionEntry] (null when no sessions exist).
final activeSessionEntryProvider = Provider<SessionEntry?>((ref) {
  return ref.watch(sessionsProvider).active;
});
