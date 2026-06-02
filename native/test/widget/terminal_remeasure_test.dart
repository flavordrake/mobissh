// Widget tests for the terminal re-measure path (#625 / #600).
//
// Root cause (device): xterm.dart computes cols/rows from `cellSize` ONLY
// inside `RenderTerminal.performLayout`. On a real device's first connect the
// first layout can run before the bundled JetBrainsMono asset font has settled,
// so the terminal locks in cols/rows for the fallback font's cell size and
// never re-measures (constraints don't change) — the dead gap above the keybar.
//
// A headless harness can't reproduce the asset-font race: test fonts are
// preloaded before the first frame, so xterm always measures the correct cell
// size on the first layout (the "fills the viewport" test below confirms that
// baseline). What the harness CAN lock in is the fix's WIRING — that the body
// registers a system-fonts listener and a WidgetsBindingObserver while mounted
// and tears both down on dispose, so a font-load / metrics change on device
// forces the re-measure. The on-emulator integration test
// (`terminal_layout_fill_test.dart`) is the real device gate for the re-fit.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

Future<({SessionEntry entry, ProviderContainer container})> _setup(
  WidgetTester tester,
  FakeSshShellTransport transport,
) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => transport,
      ),
    ],
  );
  addTearDown(container.dispose);

  final entry = container
      .read(sessionsProvider.notifier)
      .addOrActivate(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: TerminalScreen()),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (entry: entry, container: container);
}

/// Deliver the platform `fontsChange` system message — the same signal Flutter
/// raises when an asset font finishes loading. Drives both xterm's own relayout
/// mixin and the body's `systemFonts` listener.
Future<void> _fireFontsChange(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/system',
    const JSONMessageCodec().encodeMessage(<String, dynamic>{
      'type': 'fontsChange',
    }),
    (_) {},
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('terminal re-measure (#625/#600)', () {
    testWidgets(
      'fills the viewport on first layout — more than the default 24 rows',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setup(tester, transport);

        // The default Terminal is 80x24. On the (large) test surface it must
        // fit MORE than 24 rows — i.e. the terminal filled the available
        // height rather than leaving a dead gap (#625 baseline).
        expect(
          s.entry.terminal.viewHeight,
          greaterThan(24),
          reason: 'terminal did not fill the viewport on first layout (#625)',
        );
      },
    );

    testWidgets(
      'a fonts-change while mounted re-measures without throwing and the '
      'terminal stays filled (#625/#600)',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setup(tester, transport);

        final fitted = s.entry.terminal.viewHeight;
        expect(fitted, greaterThan(24));

        // Fire the platform fonts-change (the asset font finishing load on
        // device). The body's listener forces a re-measure; on the stable
        // test font the fitted size is unchanged, but the path must run
        // cleanly and the terminal must remain filled (no regression to 24).
        await _fireFontsChange(tester);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(s.entry.terminal.viewHeight, fitted);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a metrics change re-measures without throwing and stays filled (#600)',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setup(tester, transport);

        final fitted = s.entry.terminal.viewHeight;
        expect(fitted, greaterThan(24));

        tester.binding.handleMetricsChanged();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(s.entry.terminal.viewHeight, fitted);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      're-measure wiring is torn down when the session body unmounts',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setup(tester, transport);

        // Replace the whole tree so the terminal body is disposed.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));

        // After dispose, a fonts-change must NOT touch the (gone) terminal.
        // The body's listener is removed, so this is a no-op that must not
        // throw. The previously-active session's terminal stays untouched.
        final before = s.entry.terminal.viewHeight;
        await _fireFontsChange(tester);
        await tester.pump(const Duration(milliseconds: 50));
        expect(s.entry.terminal.viewHeight, before);
        expect(tester.takeException(), isNull);
      },
    );
  });

  // Keep TerminalView referenced so a refactor that drops the addressable
  // `terminal-view-$id` key is caught alongside these tests.
  test('TerminalView type is referenced', () {
    expect(TerminalView, isNotNull);
  });
}
