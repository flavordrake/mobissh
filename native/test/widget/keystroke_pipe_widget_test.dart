// Widget test: user keystrokes reach SSH stdin.
//
// Phase 2.A (#501) catches the "user types but nothing reaches SSH" class
// of regression that hit the PWA repeatedly under the hidden-textarea +
// IME tug-of-war. This test locks down the keystroke contract:
//
//   user input → Terminal.onOutput → SshShell.transport.send(...)
//
// We exercise the exact code path xterm.dart's `TerminalView` input handler
// uses on a real device: `Terminal.textInput(...)` for printable bytes,
// `Terminal.charInput(..., ctrl: true)` for control sequences. The
// `tester.sendKeyEvent`-driven path is left for the Phase 6 real-device
// stub (`test/integration_test/terminal_real_device_test.dart`); in widget
// tests the `TextInput` platform-channel connection used by xterm.dart's
// CustomTextEdit is not reliably mounted, so we exercise the model layer
// directly. That's the layer where the regression would manifest.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

void main() {
  group('SshShell keystroke pipe', () {
    test('printable character routes to fake SSH stdin', () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);

      terminal.textInput('a');
      // Let microtasks flush.
      await Future<void>.delayed(Duration.zero);

      expect(
        transport.stdinBytes.toBytes(),
        equals(Uint8List.fromList('a'.codeUnits)),
        reason: 'plain-text keystroke must reach SSH stdin',
      );
    });

    test('multiple printable keystrokes accumulate in order', () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);

      terminal.textInput('ls -la');
      // `\r` isn't in charInput's ctrl-range, so use textInput. On real
      // devices, Enter key → keyInput(TerminalKey.enter) → onOutput('\r')
      // through xterm's input handler; same wire bytes.
      terminal.textInput('\r');
      await Future<void>.delayed(Duration.zero);

      expect(
        String.fromCharCodes(transport.stdinBytes.toBytes()),
        equals('ls -la\r'),
      );
    });

    test('Ctrl-c (charInput with ctrl=true) reaches SSH stdin as ETX (0x03)',
        () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);

      final handled = terminal.charInput('c'.codeUnitAt(0), ctrl: true);
      expect(handled, isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(
        transport.stdinBytes.toBytes(),
        equals(Uint8List.fromList([0x03])),
        reason: 'Ctrl-c must reach SSH as the ETX byte',
      );
    });

    test('stdin bytes are UTF-8 — multibyte characters survive the pipe',
        () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);
      addTearDown(shell.dispose);

      shell.attach(terminal);

      // Greek letter — 2-byte UTF-8 sequence. Verifies the pipe doesn't
      // truncate to Latin-1 / lose high-bit characters.
      terminal.textInput('λ');
      await Future<void>.delayed(Duration.zero);

      // U+03BB in UTF-8 = 0xCE 0xBB
      expect(
        transport.stdinBytes.toBytes(),
        equals(Uint8List.fromList([0xCE, 0xBB])),
      );
    });

    test('dispose breaks the keystroke pipe (no more bytes sent)', () async {
      final terminal = Terminal();
      final transport = FakeSshShellTransport();
      final shell = SshShell(transport);

      shell.attach(terminal);
      terminal.textInput('x');
      await Future<void>.delayed(Duration.zero);
      expect(transport.stdinBytes.length, 1);

      shell.dispose();
      terminal.textInput('y');
      await Future<void>.delayed(Duration.zero);

      // After dispose the byte 'y' should NOT have been forwarded — the
      // `Terminal.onOutput` callback was cleared.
      expect(transport.stdinBytes.length, 1,
          reason: 'no bytes should flow after dispose');
    });
  });
}
