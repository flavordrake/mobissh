// #1229 item 3: the keybar Paste key must follow the terminal's actual DECSET
// 2004 (bracketed paste) state. It used to send the clipboard as typed text, so
// a multi-line clipboard ran line by line even when the remote asked for
// bracketed paste. The Paste key itself is not tapped here: the keybar tap path
// hangs the headless harness on Material ripple (keybar_test.dart), so this
// drives the function the key calls.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/keybar.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const clip = 'echo one\necho two';

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clip};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('2004 on: the clipboard is wrapped as one bracketed paste', () async {
    final sent = <String>[];
    final terminal = Terminal()..onOutput = sent.add;
    terminal.write('\x1b[?2004h');

    await pasteClipboardToTerminal(terminal);

    expect(sent.join(), '\x1b[200~$clip\x1b[201~');
  });

  test('2004 off: the clipboard is sent unwrapped', () async {
    final sent = <String>[];
    final terminal = Terminal()..onOutput = sent.add;

    await pasteClipboardToTerminal(terminal);

    expect(sent.join(), clip);
  });
}
