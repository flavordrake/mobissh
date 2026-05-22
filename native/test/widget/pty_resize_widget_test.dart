// Widget test: TerminalView resize triggers PTY resize on the SSH session.
//
// Phase 2.A (#501): the remote PTY must match the on-screen viewport. If
// the resize plumbing breaks, prompts render at 80×24 regardless of screen
// size — a regression that's hard to catch on emulator (PTY size doesn't
// show up in screenshots).
//
// We test the `Terminal.resize → SshShell → transport.resize` contract
// directly. `TerminalView`'s autoResize → `Terminal.resize` linkage is
// already covered by xterm.dart's own tests; mocking the `Window` from a
// Flutter widget test is brittle (cursor-blink/IME platform channels make
// `pumpAndSettle` non-deterministic). The hardware resize path is covered
// in `test/integration_test/terminal_real_device_test.dart` (Phase 6).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

void main() {
  group('SshShell PTY resize', () {
    test('attach sends an initial resize matching the Terminal viewport',
        () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);

      expect(transport.resizes, isNotEmpty,
          reason: 'shell must emit an initial resize on attach');
      final initial = transport.resizes.first;
      expect(initial.cols, terminal.viewWidth);
      expect(initial.rows, terminal.viewHeight);
    });

    test('Terminal.resize forwards (cols, rows, px, py) to the transport',
        () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);
      transport.resizes.clear(); // ignore the initial-attach resize

      // Simulate xterm.dart's `TerminalView` reporting a new viewport.
      terminal.resize(120, 40, 960, 800);

      expect(transport.resizes, hasLength(1));
      final r = transport.resizes.single;
      expect(r.cols, 120);
      expect(r.rows, 40);
      expect(r.pixelWidth, 960);
      expect(r.pixelHeight, 800);
    });

    test('multiple resizes are forwarded in order', () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);
      transport.resizes.clear();

      terminal.resize(80, 24);
      terminal.resize(100, 30);
      terminal.resize(120, 40);

      expect(transport.resizes.map((r) => '${r.cols}x${r.rows}'),
          equals(['80x24', '100x30', '120x40']));
    });

    test('dispose breaks the resize pipe (no more calls forwarded)',
        () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);

      shell.attach(terminal);
      transport.resizes.clear();

      terminal.resize(100, 30);
      expect(transport.resizes, hasLength(1));

      shell.dispose();
      terminal.resize(200, 60);

      expect(transport.resizes, hasLength(1),
          reason: 'resize after dispose must not reach the transport');
    });
  });
}
