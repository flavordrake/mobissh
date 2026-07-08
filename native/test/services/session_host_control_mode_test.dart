// SessionHost tmux control-mode (`-CC`) RENDER + RESIZE wiring — Part B (#909).
//
// Verifies the FLAG-ON behaviour of the host:
//   1. On shell open it ENTERS control mode (`tmux -CC …` written to stdin).
//   2. `%output` for the active window is PARSED, demuxed, and forwarded to the
//      UI as plain terminal bytes (the grid renders).
//   3. A PTY resize becomes a `refresh-client -C cols,rows` command line — the
//      SINGLE resize primitive — NOT a PTY winsize resize.
//   4. The FINAL settled resize size is delivered (never dropped).
// And the FLAG-OFF default is provably UNCHANGED (no tmux -CC entry; resize is a
// PTY winsize resize; raw bytes forwarded verbatim).
//
// Reuses the #osc8 / #619 host harness shape (silent socket + drivable
// controller + recording shell transport).

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/terminal/tmux_control_channel.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

class _SilentSocket implements SSHSocket {
  final _outbound = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();
  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();
  @override
  StreamSink<List<int>> get sink => _outbound.sink;
  @override
  Future<void> get done => _doneCompleter.future;
  @override
  Future<void> close() async {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    await _outbound.close();
    return done;
  }

  @override
  void destroy() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

class _DrivableController extends SshSessionController {
  _DrivableController(this._client);
  final SSHClient _client;
  @override
  SSHClient? get client => _client;
  @override
  Future<void> connect(SshConnectParams params) async {}
}

/// Shell transport recording BOTH stdin writes (`sent`) and resize calls.
class _DriveableShellTransport implements SshShellTransport {
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  final BytesBuilder sent = BytesBuilder(copy: false);
  final List<(int, int)> resizes = <(int, int)>[];

  void emit(Uint8List bytes) => _outCtrl.add(bytes);

  @override
  Stream<Uint8List> get output => _outCtrl.stream;
  @override
  void send(Uint8List bytes) => sent.add(bytes);
  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) =>
      resizes.add((cols, rows));
  @override
  Future<void> get done => _doneCompleter.future;
  @override
  void close() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    if (!_outCtrl.isClosed) _outCtrl.close();
  }
}

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);
String _s(List<int> b) => String.fromCharCodes(b);

void main() {
  Future<
      ({
        SessionHost host,
        SshSessionProxy proxy,
        InMemoryGatewayPair pair,
        List<_DriveableShellTransport> opened,
        List<String> execCommands,
        StringBuffer forwarded,
      })> setUpConnectedShell(String sid, {bool confirmHandshake = true}) async {
    final socket = _SilentSocket();
    final sentinelClient = SSHClient(socket, username: 'u');
    addTearDown(() {
      try {
        sentinelClient.close();
      } catch (_) {}
      socket.destroy();
    });

    late _DrivableController controller;
    _DrivableController factory() {
      controller = _DrivableController(sentinelClient);
      return controller;
    }

    final opened = <_DriveableShellTransport>[];
    // #982: control mode ON now opens the transport via the EXEC opener (the
    // `tmux -CC …` invocation runs AS the channel command, not typed into a
    // shell). The scrape path (flag OFF) still uses the shell opener. Both
    // register into `opened` so the existing assertions on the transport hold;
    // `execCommands` records what the exec opener was asked to run.
    final execCommands = <String>[];
    Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async {
      final t = _DriveableShellTransport();
      opened.add(t);
      return t;
    }

    Future<SshShellTransport?> execOpener(
        SSHClient c, String command, int cols, int rows) async {
      execCommands.add(command);
      final t = _DriveableShellTransport();
      opened.add(t);
      return t;
    }

    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: factory,
      shellOpener: opener,
      execOpener: execOpener,
      snapshotInterval: const Duration(hours: 1),
    );
    final proxy = SshSessionProxy(sessionId: sid, gateway: pair.uiSide);

    final forwarded = StringBuffer();
    proxy.output.listen((bytes) => forwarded.write(_s(bytes)));

    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.debugSetConnectedForTest(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // #982: a real `tmux -CC` session opens with the `\x1bP1000p` DCS handshake,
    // and the host now GATES every `-CC` write on seeing it (so a nested/plain
    // shell can't leak commands). Emit the handshake for flag-ON sessions so the
    // gate opens exactly as it does against real tmux; the flush of the initial
    // refresh-client it triggers is harmless (every assertion below clears `sent`
    // or uses startsWith/contains).
    if (confirmHandshake && tmuxControlMode && opened.isNotEmpty) {
      opened.first.emit(_b('\x1bP1000p%begin 0 0 1\n%end 0 0 1\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    addTearDown(() async {
      await proxy.dispose();
      await host.dispose();
      await pair.dispose();
    });
    return (
      host: host,
      proxy: proxy,
      pair: pair,
      opened: opened,
      execCommands: execCommands,
      forwarded: forwarded,
    );
  }

  group('flag ON — control mode', () {
    late bool prev;
    setUp(() => prev = setTmuxControlModeForTest(true));
    tearDown(() => setTmuxControlModeForTest(prev));

    test('enters control mode by RUNNING tmux -CC as the exec command — nothing '
        'is typed into the shell (#982)', () async {
      // Hold the handshake so no post-confirm resize flush muddies `sent` — we
      // assert the ENTRY writes nothing into stdin.
      final ctx =
          await setUpConnectedShell('cc:22:u:1', confirmHandshake: false);
      expect(ctx.opened, hasLength(1));
      // The `-CC` invocation is the EXEC channel's command, not a stdin write.
      expect(ctx.execCommands, hasLength(1));
      expect(ctx.execCommands.first, startsWith('tmux -CC'));
      // #982: the entry line must NEVER be typed into the shell (the leak) — the
      // exec channel carries it, so no bytes are written to stdin at entry.
      expect(ctx.opened.first.sent.length, 0,
          reason: 'the entry command must not be typed into the shell stdin — '
              'that is exactly the #982 echo leak');
    });

    test('the exec command is entryExecCommand exactly (no trailing newline)',
        () async {
      final ctx = await setUpConnectedShell('cc:22:u:exec');
      // The exec command line carries NO trailing newline (it is the channel
      // command, not a keystroke) and matches the canonical entry invocation.
      expect(ctx.execCommands.single, TmuxControlChannel.entryExecCommand);
      expect(ctx.execCommands.single.endsWith('\n'), isFalse);
    });

    test('%output renders demuxed bytes to the UI (the grid)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:2');
      final shell = ctx.opened.first;
      shell.emit(_b('%output %0 hello\\040grid\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctx.forwarded.toString(), contains('hello grid'));
      // The raw control framing is NOT forwarded verbatim.
      expect(ctx.forwarded.toString().contains('%output'), isFalse);
    });

    test('resize becomes refresh-client -C, NOT a PTY winsize resize', () async {
      final ctx = await setUpConnectedShell('cc:22:u:3');
      final shell = ctx.opened.first;
      shell.sent.clear(); // drop the entry command
      ctx.proxy.sendResize(100, 30);
      // #916: the host now also debounces refresh-client TASK-SIDE (the
      // trailing-edge settle that kills the multi-client storm), so await past
      // the settle window before asserting the single write landed.
      await Future<void>.delayed(const Duration(milliseconds: 320));
      expect(_s(shell.sent.toBytes()), contains('refresh-client -C 100,30'));
      expect(shell.resizes, isEmpty,
          reason: 'control mode must not winsize-resize the -CC PTY');
    });

    test('FINAL settled resize is delivered — never dropped (#903/#905)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:4');
      final shell = ctx.opened.first;
      shell.sent.clear();
      // The UI coalescer emits only the FINAL settled size; the host must send it.
      ctx.proxy.sendResize(88, 27);
      await Future<void>.delayed(const Duration(milliseconds: 320));
      expect(_s(shell.sent.toBytes()), contains('refresh-client -C 88,27'));
    });

    // ---- #916: refresh-client -C storm + reconnect-loop fixes ----

    test('a BURST of resizes coalesces to ONE refresh-client at final size',
        () async {
      final ctx = await setUpConnectedShell('cc:22:u:storm1');
      final shell = ctx.opened.first;
      shell.sent.clear();
      // The owner's `58,57 ↔ 58,34` alternation: a keyboard-toggle / multi-client
      // burst. The host must collapse it to ONE refresh-client at the final size.
      ctx.proxy.sendResize(58, 57);
      ctx.proxy.sendResize(58, 50);
      ctx.proxy.sendResize(58, 44);
      ctx.proxy.sendResize(58, 34);
      await Future<void>.delayed(const Duration(milliseconds: 320));
      final written = _s(shell.sent.toBytes());
      final count = 'refresh-client -C'.allMatches(written).length;
      expect(count, 1, reason: 'BOUNDED — one settled write, not a storm');
      expect(written, contains('refresh-client -C 58,34'));
    });

    test('an active-window switch repaints PROMPTLY (not swallowed by the '
        'resize coalescer dedup) — #916 regression fix', () async {
      final ctx = await setUpConnectedShell('cc:22:u:storm2');
      final shell = ctx.opened.first;
      // Establish a size first so the redraw has dims to repaint at — and so the
      // resize coalescer has ALREADY emitted that size (its last-emitted dims).
      ctx.proxy.sendResize(58, 34);
      await Future<void>.delayed(const Duration(milliseconds: 320));
      shell.sent.clear();
      // A SINGLE authoritative window switch. The switch re-emits refresh-client
      // at the SAME 58,34 dims to force a repaint of the new window. The REGRESSION
      // routed this through the resize coalescer, whose same-size DEDUP (and 250ms
      // settle) swallowed it → the new window never rendered (blank grid). The fix
      // writes the switch redraw DIRECTLY, decoupled from the coalescer, so it must
      // appear PROMPTLY and at the same dims (no dedup drop).
      shell.emit(_b('%session-window-changed \$0 @1\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final written = _s(shell.sent.toBytes());
      expect(written, contains('refresh-client -C 58,34'),
          reason: 'the switch redraw must NOT be dedup-swallowed by the resize '
              'coalescer — it must repaint the new window promptly + directly');
    });

    test('a switch redraw does NOT go through the resize coalescer settle '
        '(direct write, no 250ms delay) — #916', () async {
      final ctx = await setUpConnectedShell('cc:22:u:storm3');
      final shell = ctx.opened.first;
      ctx.proxy.sendResize(58, 34);
      await Future<void>.delayed(const Duration(milliseconds: 320));
      shell.sent.clear();
      // The switch repaint is a DIRECT write, so it lands well before any
      // trailing-edge settle window — a tight delay is enough to observe it.
      shell.emit(_b('%session-window-changed \$0 @2\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), contains('refresh-client -C'),
          reason: 'switch redraw must be written immediately, not deferred to '
              'the resize coalescer settle');
    });

    test('%exit surfaces ONE clean shell close (no silent re-ingest loop)',
        () async {
      final ctx = await setUpConnectedShell('cc:22:u:exit');
      final shell = ctx.opened.first;
      final doneFired = shell.done.then((_) => true);
      // tmux detaches / server dies → %exit. The host must CLOSE the shell so the
      // controller drives a SINGLE reconnect, not silently ignore it (the #916
      // half-dead-channel loop). The transport's done must fire.
      shell.emit(_b('%exit\n'));
      final didClose = await doneFired.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () => false,
      );
      expect(didClose, isTrue,
          reason: '%exit must close the shell transport exactly once');
    });

    // ---- #906 switch fix: query the window list on attach ----

    test('ATTACH requests list-windows so a pre-existing session is tappable',
        () async {
      final ctx = await setUpConnectedShell('cc:22:u:winlist');
      final shell = ctx.opened.first;
      shell.sent.clear();
      // tmux -CC attach to a PRE-EXISTING session: %session-changed with NO
      // %window-add for the pre-attach windows. The host must query list-windows.
      shell.emit(_b('%session-changed \$0 main\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final written = _s(shell.sent.toBytes());
      expect(written, contains('list-windows -F'),
          reason: 'attach must query the window list so a status-bar tap can '
              'resolve a target on a pre-existing session (the "not switching" bug)');
    });

    // ---- #911 Part C: atomic control-command delivery + real gestures ----

    test('a multi-token control command is delivered as ONE atomic line', () async {
      final ctx = await setUpConnectedShell('cc:22:u:5');
      final shell = ctx.opened.first;
      shell.sent.clear();
      ctx.proxy.sendControlCommand('select-window -t @1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final written = _s(shell.sent.toBytes());
      // The WHOLE multi-token line survives intact with exactly one trailing
      // newline (the Part B fragmentation bug would have split it).
      expect(written, 'select-window -t @1\n');
      expect('\n'.allMatches(written).length, 1);
    });

    test('swipe RIGHT gesture issues next-window over the channel', () async {
      final ctx = await setUpConnectedShell('cc:22:u:6');
      final shell = ctx.opened.first;
      // Populate the channel's window list.
      shell.emit(_b('%window-add @0\n'));
      shell.emit(_b('%window-add @1\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      shell.sent.clear();
      ctx.proxy.sendTmuxGesture(TmuxWindowGesture.nextWindow);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), 'next-window\n');
    });

    test('swipe LEFT gesture issues previous-window over the channel', () async {
      final ctx = await setUpConnectedShell('cc:22:u:7');
      final shell = ctx.opened.first;
      shell.sent.clear();
      ctx.proxy.sendTmuxGesture(TmuxWindowGesture.previousWindow);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), 'previous-window\n');
    });

    test('status-bar tap maps the column to select-window for that window', () async {
      final ctx = await setUpConnectedShell('cc:22:u:8');
      final shell = ctx.opened.first;
      shell.emit(_b('%window-add @0\n'));
      shell.emit(_b('%window-add @1\n'));
      shell.emit(_b('%window-add @2\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      shell.sent.clear();
      // Tap in the middle segment (window index 1) of a 90-col status line.
      ctx.proxy.sendTmuxGesture(
        TmuxWindowGesture.tapStatusCol,
        statusCol: 45,
        statusCols: 90,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), 'select-window -t @1\n');
    });

    test('status-bar tap with no known windows is a no-op (no write)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:9');
      final shell = ctx.opened.first;
      shell.sent.clear();
      ctx.proxy.sendTmuxGesture(
        TmuxWindowGesture.tapStatusCol,
        statusCol: 10,
        statusCols: 80,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shell.sent.length, 0);
    });

    // ---- #982: handshake gate — NO -CC write leaks before the DCS ----

    test('BEFORE the handshake, a resize does NOT leak refresh-client into the '
        'shell (nothing was written — entry runs as the exec command)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:gate1',
          confirmHandshake: false);
      final shell = ctx.opened.first;
      // #982: the entry command runs as the EXEC channel command, so NOTHING is
      // written to stdin at entry — not even the entry line.
      expect(shell.sent.length, 0);
      expect(ctx.execCommands.single, startsWith('tmux -CC'));
      shell.sent.clear();
      ctx.proxy.sendResize(100, 30);
      // Past the resize-coalescer settle: with the gate closed it must be BUFFERED,
      // not written — a nested/plain shell would echo it as literal text.
      await Future<void>.delayed(const Duration(milliseconds: 320));
      expect(_s(shell.sent.toBytes()).contains('refresh-client'), isFalse,
          reason: 'refresh-client leaked before the -CC handshake confirmed');
    });

    test('BEFORE the handshake, control commands + gestures are gated (no leak)',
        () async {
      final ctx = await setUpConnectedShell('cc:22:u:gate2',
          confirmHandshake: false);
      final shell = ctx.opened.first;
      shell.sent.clear();
      ctx.proxy.sendControlCommand('select-window -t @1');
      ctx.proxy.sendTmuxGesture(TmuxWindowGesture.nextWindow);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shell.sent.length, 0,
          reason: 'a -CC command leaked into the pane before the handshake');
    });

    test('the BUFFERED resize FLUSHES once the handshake confirms', () async {
      final ctx = await setUpConnectedShell('cc:22:u:gate3',
          confirmHandshake: false);
      final shell = ctx.opened.first;
      shell.sent.clear();
      ctx.proxy.sendResize(111, 41);
      await Future<void>.delayed(const Duration(milliseconds: 320));
      // Still gated — nothing written yet.
      expect(_s(shell.sent.toBytes()).contains('refresh-client'), isFalse);
      // The DCS arrives → the gate opens and the buffered size flushes ONCE.
      shell.emit(_b('\x1bP1000p%begin 0 0 1\n%end 0 0 1\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), contains('refresh-client -C 111,41'));
    });

    test('an ATTACH capture requested in the SAME chunk as the handshake is '
        'NOT gated out — capture-pane fires on confirm (#982 regression)',
        () async {
      final ctx = await setUpConnectedShell('cc:22:u:attach1',
          confirmHandshake: false);
      final shell = ctx.opened.first;
      shell.sent.clear();
      // Real `-CC attach`: the DCS and `%session-changed` (→ captureRequested)
      // can arrive in ONE chunk. The attach capture is the ONLY paint of the
      // pre-existing screen, so it must be sent the instant the gate opens.
      shell.emit(_b('\x1bP1000p%begin 0 0 1\n%end 0 0 1\n%session-changed \$0 main\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), contains('capture-pane'),
          reason: 'the attach capture was gated out — Stage-1 attach-render '
              'regressed');
      // Exactly ONE capture (no double-send between confirm + captureRequested).
      expect('capture-pane'.allMatches(_s(shell.sent.toBytes())).length, 1);
    });

    test('an attach capture requested BEFORE the DCS is buffered and flushed on '
        'confirm (#982)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:attach2',
          confirmHandshake: false);
      final shell = ctx.opened.first;
      shell.sent.clear();
      // captureRequested arrives while the gate is closed → buffered, NOT sent.
      shell.emit(_b('%session-changed \$0 main\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()).contains('capture-pane'), isFalse,
          reason: 'a capture must not leak before the handshake');
      // The DCS opens the gate → the buffered capture flushes exactly once.
      shell.emit(_b('\x1bP1000p%begin 0 0 1\n%end 0 0 1\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), contains('capture-pane'));
      expect('capture-pane'.allMatches(_s(shell.sent.toBytes())).length, 1);
    });

    test('handshake NEVER confirmed → FALLBACK to scrape: the -CC channel is '
        'torn down and a resize becomes a PTY winsize resize (#982)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:fallback',
          confirmHandshake: false);
      final shell = ctx.opened.first;
      // Wait past the bounded handshake timeout — control mode FAILED (nested/no
      // tmux). The host must fall back so the connection still WORKS.
      await Future<void>.delayed(kTmuxHandshakeTimeout +
          const Duration(milliseconds: 300));
      shell.sent.clear();
      shell.resizes.clear();
      // Post-fallback the session is the plain scrape path: raw bytes render and
      // a resize drives the PTY winsize (NOT refresh-client).
      shell.emit(_b('\x1b[32mscrape-lives\x1b[0m\r\n'));
      ctx.proxy.sendResize(120, 40);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctx.forwarded.toString(), contains('scrape-lives'));
      expect(shell.resizes, contains((120, 40)),
          reason: 'after fallback a resize must winsize the PTY, not refresh-client');
      expect(_s(shell.sent.toBytes()).contains('refresh-client'), isFalse);
    });
  });

  group('flag OFF — scrape path unchanged (shipped default)', () {
    test('does NOT enter control mode; raw bytes forwarded verbatim', () async {
      final ctx = await setUpConnectedShell('plain:22:u:1');
      final shell = ctx.opened.first;
      // No tmux -CC entry written.
      expect(shell.sent.length, 0);
      // #982: the scrape path opens the interactive SHELL, never the exec opener.
      expect(ctx.execCommands, isEmpty,
          reason: 'flag OFF must use the shell opener, not the -CC exec opener');
      shell.emit(_b('\x1b[32mhello\x1b[0m\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctx.forwarded.toString(), contains('\x1b[32mhello\x1b[0m\r\n'));
    });

    test('resize is a PTY winsize resize (not refresh-client -C)', () async {
      final ctx = await setUpConnectedShell('plain:22:u:2');
      final shell = ctx.opened.first;
      ctx.proxy.sendResize(120, 40);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shell.resizes, contains((120, 40)));
      expect(_s(shell.sent.toBytes()).contains('refresh-client'), isFalse);
    });

    test('control commands + window gestures are IGNORED (no -CC channel)', () async {
      // #911: with the flag OFF there is no tmuxChannel, so a control command or
      // a window gesture command must be a pure no-op — the scrape path never
      // issues control commands. Nothing is written to the shell.
      final ctx = await setUpConnectedShell('plain:22:u:3');
      final shell = ctx.opened.first;
      shell.sent.clear();
      ctx.proxy.sendControlCommand('select-window -t @1');
      ctx.proxy.sendTmuxGesture(TmuxWindowGesture.nextWindow);
      ctx.proxy.sendTmuxGesture(
        TmuxWindowGesture.tapStatusCol,
        statusCol: 5,
        statusCols: 80,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shell.sent.length, 0);
    });
  });
}
