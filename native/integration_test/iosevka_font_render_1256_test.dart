// On-emulator check for #1256: the bundled Iosevka Term face actually renders
// in the terminal, not a silent fallback.
//
// Selects IosevkaTerm as the default font, connects to test-sshd, prints Latin,
// box-drawing, block, Braille and Powerline text, and asserts:
//   - the terminal renderer is themed with family IosevkaTerm;
//   - the measured cell is Iosevka-narrow: Iosevka Term advances 0.5 em, the
//     JetBrains Mono default 0.6 em. Switching the session to JetBrains Mono
//     must widen the cell, which only happens if Iosevka was really loaded
//     (a fallback face would measure the same either way).
// The glyphs themselves (no tofu) are checked by screenshot: the orchestrator
// runs `scripts/emu-shot.sh iosevka-1256` while IOSEVKA1256_SHOT_WINDOW_OPEN is
// logged and reads the PNG.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _iosevka = 'IosevkaTerm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Iosevka Term renders in the terminal (#1256)', (tester) async {
    FlutterForegroundTask.initCommunicationPort();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(fontFamilyProvider.notifier).set(_iosevka);
    // Prefs persist on the device across tests: put the default back.
    addTearDown(
      () => container.read(fontFamilyProvider.notifier).set(fontFamilyDefault),
    );

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

    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    final sessionId = entry!.id;
    expect(container.read(sessionFontFamilyProvider(sessionId)), _iosevka);

    final out = <int>[];
    final sub = entry.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);
    for (var i = 0; i < 40 && out.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

    final termKey = find.byKey(Key('ghostty-terminal-$sessionId'));
    expect(termKey, findsOneWidget, reason: 'no ghostty terminal view');
    TerminalRenderer renderer() => tester.widget<TerminalRenderer>(
      find.descendant(of: termKey, matching: find.byType(TerminalRenderer)),
    );
    expect(renderer().theme.fontFamily, _iosevka);
    final fontSize = renderer().theme.fontSize;

    entry.proxy.sendInput(
      Uint8List.fromList(
        utf8.encode(
          "clear; printf '%s\\n' "
          "'IOSEVKA1256 The quick brown fox jumps over 0123456789' "
          "'Latin-1: café naïve façade Ångström ½ ± µ ß' "
          "'┌──────┬──────┐' '│ box  │ ╳ ╬ │' '├══════╪══════┤' "
          "'└──────┴──────┘' 'blocks: ░▒▓█▀▄▌▐' "
          "'braille: ⠁⠃⠇⡇⣇⣧⣷⣿' 'arrows: ← → ↑ ↓ ⇒' "
          "'powerline:   ' 'END1256'\n",
        ),
      ),
    );
    var printed = false;
    for (var i = 0; i < 40 && !printed; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      printed = utf8.decode(out, allowMalformed: true).contains('\nEND1256');
    }
    expect(printed, isTrue, reason: 'sample text never echoed back');

    // Cell metrics settle after the font bytes resolve; poll, bounded.
    Size? cell() => GhosttyTerminalView.debugCellSizes[sessionId];
    for (var i = 0; i < 20 && cell() == null; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final iosevkaCell = cell();
    expect(iosevkaCell, isNotNull, reason: 'no measured cell size');
    final ratio = iosevkaCell!.width / fontSize;
    debugPrint('IOSEVKA1256 cell=$iosevkaCell fontSize=$fontSize ratio=$ratio');
    expect(
      ratio,
      lessThan(0.56),
      reason: 'Iosevka Term advances 0.5 em; a wider cell means a fallback face',
    );

    debugPrint('IOSEVKA1256_SHOT_WINDOW_OPEN');
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    debugPrint('IOSEVKA1256_SHOT_WINDOW_CLOSED');

    container
        .read(sessionAppearanceProvider.notifier)
        .setFontFamily(sessionId, fontFamilyDefault);
    for (var i = 0; i < 20 && cell()!.width <= iosevkaCell.width; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('IOSEVKA1256 jetbrains cell=${cell()}');
    expect(
      cell()!.width,
      greaterThan(iosevkaCell.width * 1.1),
      reason: 'switching to JetBrains Mono must widen the cell (0.5 → 0.6 em)',
    );
  });
}
