// Widget tests for the centered session title (#651) + per-session profile
// color swatch tag (#653) on the bottom `_SessionBar`.
//
// Mirrors the PWA: the session bar shows a colored `session-dot` swatch next to
// the (now centered) session label; the SAME color identifies the SAME profile
// everywhere. The swatch color is the profile color when set, else the session's
// terminal-theme accent — it must ALWAYS render a sensible color (never blank).
//
// Harness mirrors terminal_remeasure_test.dart: an InMemoryGatewayPair + a real
// SshShell attached to the session terminal so TerminalScreen mounts the bar.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_ssh_shell_transport.dart';

/// Mount TerminalScreen with one shell-ready session. Returns the container +
/// the session entry so a test can seed per-session prefs (e.g. the color).
Future<({SessionEntry entry, ProviderContainer container})> _mount(
  WidgetTester tester,
  FakeSshShellTransport transport,
) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());
  late final SessionEntry entry;
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellProvider.overrideWith((ref, sessionId) async {
        final shell = SshShell(transport);
        shell.attach(entry.terminal);
        ref.onDispose(shell.dispose);
        return shell;
      }),
    ],
  );
  addTearDown(container.dispose);

  entry = container
      .read(sessionsProvider.notifier)
      .addOrActivate(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
        title: 'My Server',
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('session bar — centered title (#651) + color swatch (#653)', () {
    testWidgets('the title is horizontally centered in the bar', (
      tester,
    ) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      await _mount(tester, transport);

      final barCenter = tester.getCenter(find.byKey(const Key('session-bar')));
      // The label text sits in the centered overlay layer.
      final titleCenter = tester.getCenter(find.text('My Server'));

      // The title's center x must track the bar's center x within a small
      // tolerance (the swatch sits just left of the text, so the swatch+title
      // group is centered — the text itself is a hair right of dead-center).
      expect(
        (titleCenter.dx - barCenter.dx).abs(),
        lessThan(24),
        reason:
            'session title is not centered over the bar — titleCenter.dx='
            '${titleCenter.dx}, barCenter.dx=${barCenter.dx}',
      );
    });

    testWidgets('a color swatch renders with the seeded profile color', (
      tester,
    ) async {
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final s = await _mount(tester, transport);

      // Seed an explicit per-session profile color (the connect path's
      // setColor seed). #FF8800 → opaque orange.
      const seeded = Color(0xFFFF8800);
      s.container
          .read(sessionAppearanceProvider.notifier)
          .setColor(s.entry.id, seeded);
      await tester.pump();

      final swatch = tester.widget<Container>(
        find.byKey(const Key('session-bar-swatch')),
      );
      final decoration = swatch.decoration as BoxDecoration;
      expect(decoration.color, seeded);
      expect(decoration.shape, BoxShape.circle);
    });

    testWidgets(
      'the swatch falls back to the theme accent when no profile color is set',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _mount(tester, transport);

        // No setColor call → sessionColorProvider yields null → the bar falls
        // back to the session's terminal-theme cursor accent. The swatch must
        // still render a non-null, sensible color (never blank).
        final palette = s.container.read(
          sessionTerminalThemeProvider(s.entry.id),
        );
        final swatch = tester.widget<Container>(
          find.byKey(const Key('session-bar-swatch')),
        );
        final decoration = swatch.decoration as BoxDecoration;
        expect(decoration.color, isNotNull);
        expect(decoration.color, palette.theme.cursor);
      },
    );
  });

  group('colorFromHex (#653)', () {
    test('parses #RRGGBB as opaque', () {
      expect(colorFromHex('#00ff88'), const Color(0xFF00FF88));
      expect(colorFromHex('00ff88'), const Color(0xFF00FF88));
    });
    test('parses #AARRGGBB verbatim', () {
      expect(colorFromHex('#8000ff88'), const Color(0x8000FF88));
    });
    test('returns null for empty/invalid', () {
      expect(colorFromHex(null), isNull);
      expect(colorFromHex(''), isNull);
      expect(colorFromHex('  '), isNull);
      expect(colorFromHex('#zzz'), isNull);
      expect(colorFromHex('#12345'), isNull);
    });
  });
}
