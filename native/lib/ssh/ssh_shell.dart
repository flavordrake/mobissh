// PTY shell channel + bidirectional byte pipe between xterm.dart's
// [Terminal] model and a dartssh2 PTY-mode session.
//
// Phase 2.A (#501): wraps `dartssh2.SSHSession` so the rest of the app can
// consume a small, testable surface. The transport is abstracted behind
// [SshShellTransport] so widget tests can substitute a fake without
// instantiating real SSH plumbing.
//
// Out of scope (deferred to 2.B/2.C/2.D):
//   - Selection / clipboard
//   - URL + path link detection
//   - Pinch-to-zoom font sizing
//   - IME / soft-keyboard polish beyond what xterm.dart gives us for free

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' as ssh;
import 'package:xterm/xterm.dart';

/// Transport-level abstraction over a PTY-backed SSH channel.
///
/// The real implementation wraps a `dartssh2.SSHSession`; tests provide a
/// fake that captures bytes written to stdin and resize calls so the
/// keystroke pipe + resize wiring can be asserted without a real network
/// connection. Keeping this interface small is deliberate — Phase 2.A only
/// needs read/write/resize/close. EOF, exit codes, and signals come later.
abstract class SshShellTransport {
  /// Bytes coming from the remote process (stdout merged with stderr by
  /// default). Listeners feed these to `Terminal.write(...)`.
  Stream<Uint8List> get output;

  /// Send raw bytes to the remote process. Called by [SshShell] each time
  /// the xterm `Terminal` emits via `onOutput`.
  void send(Uint8List bytes);

  /// Inform the remote process that the PTY dimensions changed.
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0});

  /// Completes when the channel closes. The shell uses this to detach from
  /// the terminal.
  Future<void> get done;

  /// Tear down the channel.
  void close();
}

/// Adapter from [SshShellTransport] to `dartssh2.SSHSession`.
class _SshSessionTransport implements SshShellTransport {
  _SshSessionTransport(this._session) : output = _mergeStdoutStderr(_session);

  final ssh.SSHSession _session;

  @override
  final Stream<Uint8List> output;

  @override
  Future<void> get done => _session.done;

  @override
  void send(Uint8List bytes) {
    _session.write(bytes);
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    _session.resizeTerminal(cols, rows, pixelWidth, pixelHeight);
  }

  @override
  void close() {
    _session.close();
  }

  /// Merge stdout and stderr into a single broadcast stream. PTY mode
  /// already collapses stderr into stdout, but we listen on both for safety
  /// — some servers split them, and the user sees identical output either
  /// way.
  static Stream<Uint8List> _mergeStdoutStderr(ssh.SSHSession session) {
    final ctrl = StreamController<Uint8List>.broadcast();
    final stdoutSub = session.stdout.listen(ctrl.add, onError: ctrl.addError);
    final stderrSub = session.stderr.listen(ctrl.add, onError: ctrl.addError);
    Future<void> closeOnDone() async {
      await session.done;
      await stdoutSub.cancel();
      await stderrSub.cancel();
      if (!ctrl.isClosed) await ctrl.close();
    }

    unawaited(closeOnDone());
    return ctrl.stream;
  }
}

/// Open a real PTY shell on [client] and return an [SshShellTransport]
/// wrapping the resulting `dartssh2.SSHSession`.
///
/// Initial PTY size is read from the [terminal] model so the remote shell
/// matches the on-screen viewport from the first byte.
Future<SshShellTransport> openSshShellTransport(
  ssh.SSHClient client,
  Terminal terminal,
) async {
  return openSshShellTransportSized(
    client,
    width: terminal.viewWidth,
    height: terminal.viewHeight,
  );
}

/// Open a PTY shell with explicit dimensions — for the task isolate, which
/// hosts the `SSHClient` but has no UI [Terminal] to read size from. The UI's
/// first resize command (sent on attach) corrects the dims immediately.
Future<SshShellTransport> openSshShellTransportSized(
  ssh.SSHClient client, {
  int width = 80,
  int height = 24,
}) async {
  final session = await client.shell(
    pty: ssh.SSHPtyConfig(width: width, height: height),
  );
  return _SshSessionTransport(session);
}

/// Owns the bidirectional byte pipe between a [Terminal] model and an SSH
/// PTY channel.
///
/// Lifecycle:
///   1. `final shell = SshShell(transport);`
///   2. `shell.attach(terminal)` — subscribes to `transport.output` and
///      forwards to `terminal.write(...)`; wires `terminal.onOutput` to
///      `transport.send(...)` and `terminal.onResize` to
///      `transport.resize(...)`. Sends one initial resize to align the PTY
///      with the current viewport.
///   3. `shell.dispose()` — cancels subscriptions, closes transport, clears
///      the terminal's callbacks (so a future attach doesn't double-fire).
class SshShell {
  SshShell(this.transport);

  final SshShellTransport transport;

  Terminal? _terminal;
  StreamSubscription<Uint8List>? _outputSub;
  bool _disposed = false;

  /// Whether this shell has been attached to a terminal.
  bool get isAttached => _terminal != null;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Bind a [terminal] to this shell. Idempotent for the same terminal;
  /// calling twice with different terminals throws.
  void attach(Terminal terminal) {
    if (_disposed) {
      throw StateError('SshShell.attach called after dispose');
    }
    if (_terminal != null) {
      if (identical(_terminal, terminal)) return;
      throw StateError(
        'SshShell.attach: already attached to a different terminal',
      );
    }
    _terminal = terminal;

    _outputSub = transport.output.listen(
      (bytes) {
        // dartssh2 already decodes terminal frames as raw bytes; xterm's
        // `write` expects a string. UTF-8 is the safe default for modern
        // shells. Malformed sequences are replaced rather than thrown — the
        // user sees a question-mark, not a crash.
        final decoded = utf8.decode(bytes, allowMalformed: true);
        terminal.write(decoded);
      },
      onError: (Object e, StackTrace st) {
        // Surface the error inline as a final escape sequence. Phase 2.A
        // keeps this minimal; richer error handling lands with the state
        // machine in 2.D.
        terminal.write('\r\n[shell error: $e]\r\n');
      },
    );

    terminal.onOutput = (data) {
      if (_disposed) return;
      transport.send(Uint8List.fromList(utf8.encode(data)));
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      try {
        transport.resize(
          width,
          height,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
        );
      } catch (_) {
        // dartssh2 throws on negative dims; widget tests sometimes pass 0
        // before the first frame. Swallow — the next real resize will fix
        // it.
      }
    };

    // Send one resize immediately so the remote PTY matches the visible
    // viewport before the first shell prompt is rendered.
    try {
      transport.resize(terminal.viewWidth, terminal.viewHeight);
    } catch (_) {
      /* see above */
    }

    // Auto-dispose when the remote channel closes.
    unawaited(
      transport.done.then((_) {
        if (!_disposed) dispose();
      }),
    );
  }

  /// Detach + close the transport. Safe to call multiple times.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _outputSub?.cancel();
    _outputSub = null;
    final term = _terminal;
    if (term != null) {
      term.onOutput = null;
      term.onResize = null;
    }
    _terminal = null;
    try {
      transport.close();
    } catch (_) {
      /* ignore */
    }
  }
}
