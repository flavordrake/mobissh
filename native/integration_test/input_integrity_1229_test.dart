// On-emulator #1229: the bytes the user's input puts on the remote are exact.
//
// Drives the REAL compose bar and keybar Paste key against test-sshd and reads
// the remote side raw (`head -c N | od -An -tx1` on the PTY), so what is
// asserted is what the shell actually received:
//   1. compose submit of multibyte + emoji text arrives byte-exact (UTF-8);
//   2. compose multi-line with DECSET 2004 ON arrives as ONE bracketed paste;
//   3. compose multi-line with 2004 OFF arrives unwrapped (no literal markers);
//   4. keybar Paste with 2004 ON arrives as one bracketed paste;
//   5. after a disconnect, a compose submit keeps the text and shows the
//      not-sent indicator instead of clearing it as if sent.
// The DECSET is emitted by the remote (`printf`), so the test also proves the
// app tracks the mode from the real byte stream.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';

import 'support/connect_helpers.dart';

String hexOf(List<int> bytes) =>
    bytes.map((b) => ' ${b.toRadixString(16).padLeft(2, '0')}').join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compose + paste bytes are exact and follow DECSET 2004 (#1229)',
      (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );

    var connected = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final accept = find.text('Trust + connect');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
        connected = true;
        break;
      }
    }
    expect(connected, isTrue, reason: 'never reached the terminal screen');

    final entry = container.read(sessionsProvider).active!;
    final out = <int>[];
    final sub = entry.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    Future<bool> waitFor(bool Function() cond, {int ticks = 40}) async {
      for (var i = 0; i < ticks; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (cond()) return true;
      }
      return false;
    }

    String outText() => utf8.decode(out, allowMalformed: true);

    // Wait for the prompt, then run a remote reader for [n] bytes.
    expect(await waitFor(() => out.isNotEmpty), isTrue, reason: 'no prompt');
    Future<void> remoteReader(String mode, int n) async {
      out.clear();
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode(
        "printf '\\033[?2004$mode'; head -c $n | od -An -tx1\n",
      )));
      // Let printf's DECSET reach both terminal parsers and head start.
      await tester.pump(const Duration(seconds: 1));
      out.clear();
    }

    Future<void> composeSubmit(String text) async {
      await container.read(composeBarVisibleProvider.notifier).set(true);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byKey(const Key('compose-bar-input')), text);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('compose-bar-submit')));
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> expectRemoteHex(List<int> bytes, String why) async {
      final want = hexOf(bytes);
      final ok = await waitFor(() => outText().contains(want));
      expect(ok, isTrue, reason: '$why: wanted "$want" in:\n${outText()}');
    }

    // 1. multibyte + emoji through the compose bar, byte-exact.
    const uni = 'héllo 🙂';
    final uniBytes = [...utf8.encode(uni), 0x0a]; // submit's \r → \n (icrnl)
    await remoteReader('l', uniBytes.length);
    await composeSubmit(uni);
    await expectRemoteHex(uniBytes, 'compose multibyte');

    // 2. multi-line compose with 2004 ON → one bracketed paste.
    final on = [
      ...'\x1b[200~a\nb\x1b[201~'.codeUnits,
      0x0a,
    ];
    await remoteReader('h', on.length);
    await composeSubmit('a\nb');
    await expectRemoteHex(on, 'compose 2004 on');

    // 3. multi-line compose with 2004 OFF → no markers.
    final off = 'a\nb\n'.codeUnits;
    await remoteReader('l', off.length);
    await composeSubmit('a\nb');
    await expectRemoteHex(off, 'compose 2004 off');

    // 4. keybar Paste with 2004 ON → one bracketed paste.
    await Clipboard.setData(const ClipboardData(text: 'p\nq'));
    final pasteOn = [...'\x1b[200~p\nq\x1b[201~'.codeUnits, 0x0a];
    await remoteReader('h', pasteOn.length);
    final pasteKey = find.byKey(const Key('keybar-btn-keyPaste'));
    expect(pasteKey, findsOneWidget, reason: 'keybar Paste key not shown');
    await tester.ensureVisible(pasteKey);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(pasteKey);
    await tester.pump(const Duration(milliseconds: 500));
    entry.proxy.sendInput(Uint8List.fromList([0x0a]));
    await expectRemoteHex(pasteOn, 'keybar paste 2004 on');

    // 5. not live: a compose submit keeps the text and says so.
    entry.proxy.disconnect();
    expect(
      await waitFor(
        () => entry.proxy.data.state != SshSessionState.connected,
      ),
      isTrue,
      reason: 'session never left connected after disconnect',
    );
    await composeSubmit('kept text');
    expect(find.byKey(const Key('compose-bar-not-sent')), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('compose-bar-input')),
    );
    expect(field.controller!.text, 'kept text');
  });
}
