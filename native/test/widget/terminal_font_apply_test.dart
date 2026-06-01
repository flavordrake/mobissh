// Per-session font size must APPLY to the rendered terminal (#616).
//
// The per-session model + the session-menu stepper are already covered by
// per_session_appearance_test.dart and session_menu_appearance_test.dart. The
// device bug (#616 — "adjusted font size several times, not persisting per
// terminal") is at the RENDER layer: stepping the active session's font must
// actually reach the live `TerminalView` so the glyphs resize, and must NOT
// resize a sibling session's terminal (per-session isolation at the widget).
//
// These render-layer assertions are the gap. They read the `TerminalView` that
// `_SessionTerminalBody` builds for a given session and assert its
// `textStyle.fontSize`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ssh_shell_transport.dart';

ProviderContainer _makeContainer(FakeSshShellTransport transport) {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      sshShellOpenerProvider.overrideWithValue(
        (ref, sessionId, terminal) async => transport,
      ),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host) {
  return c
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The `fontSize` the `TerminalView` for [sessionId] is currently rendering.
/// `skipOffstage: false` because inactive sessions live offstage in the
/// terminal screen's `IndexedStack`.
double _terminalFontSize(WidgetTester tester, String sessionId) {
  final view = tester.widget<TerminalView>(
    find.byKey(Key('terminal-view-$sessionId'), skipOffstage: false),
  );
  return view.textStyle.fontSize;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('stepping the active session font resizes its TerminalView', (
    tester,
  ) async {
    final transport = FakeSshShellTransport();
    addTearDown(transport.close);
    final container = _makeContainer(transport);
    final a = _add(container, 'host-a');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TerminalScreen()),
      ),
    );
    await _pumpFrames(tester);

    expect(_terminalFontSize(tester, a.id), fontSizeDefault);

    // Step the active session's font up twice via the notifier (the same call
    // the session-menu stepper makes).
    container
        .read(sessionAppearanceProvider.notifier)
        .adjustFontSize(a.id, kFontSizeStep);
    container
        .read(sessionAppearanceProvider.notifier)
        .adjustFontSize(a.id, kFontSizeStep);
    await _pumpFrames(tester);

    expect(
      _terminalFontSize(tester, a.id),
      fontSizeDefault + 2 * kFontSizeStep,
      reason: 'the live terminal must reflect the per-session font change',
    );
  });

  testWidgets('resizing one session does NOT resize the other terminal', (
    tester,
  ) async {
    final transport = FakeSshShellTransport();
    addTearDown(transport.close);
    final container = _makeContainer(transport);
    final a = _add(container, 'host-a');
    final b = _add(container, 'host-b'); // b is active

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TerminalScreen()),
      ),
    );
    await _pumpFrames(tester);

    container.read(sessionAppearanceProvider.notifier).setFontSize(b.id, 22);
    await _pumpFrames(tester);

    expect(_terminalFontSize(tester, b.id), 22);
    expect(
      _terminalFontSize(tester, a.id),
      fontSizeDefault,
      reason: 'sibling session terminal font must be untouched',
    );
  });

  testWidgets('a freshly-added session terminal starts from the default', (
    tester,
  ) async {
    final transport = FakeSshShellTransport();
    addTearDown(transport.close);
    final container = _makeContainer(transport);
    final a = _add(container, 'host-a');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TerminalScreen()),
      ),
    );
    await _pumpFrames(tester);

    // Shrink session A.
    container.read(sessionAppearanceProvider.notifier).setFontSize(a.id, 26);
    await _pumpFrames(tester);
    expect(_terminalFontSize(tester, a.id), 26);

    // A new session must render at the default, not A's override.
    final b = _add(container, 'host-b');
    await _pumpFrames(tester);
    expect(
      _terminalFontSize(tester, b.id),
      fontSizeDefault,
      reason: 'a new session terminal starts from the global default',
    );
  });
}
