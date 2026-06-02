// On-emulator TERMINAL-LAYOUT / RESIZE smoke (#625 + #600).
//
// The device bugs (build 030596c):
//   #625 — on FIRST connect the terminal does NOT fill the screen: a dead
//          vertical gap sits between the last terminal line and the keybar. The
//          terminal locked in cols/rows for a stale (fallback-font) cell size on
//          the first layout and never re-measured.
//   #600 — terminal layout breaks on viewport changes (keyboard show/hide,
//          keybar toggle, rotation, reconnect) "more than the PWA": the PTY size
//          is not re-sent on every rendered-size change, so the server's idea of
//          cols/rows diverges from what's rendered.
//
// Headless widget tests CANNOT reproduce these — test fonts are preloaded before
// the first frame, so xterm always measures the correct cell size and always
// re-fits. This test runs on the REAL emulator (real font load + real layout)
// and asserts the device contract:
//   1. After connect, the terminal FILLS the tall emulator viewport — many more
//      than the default 24 rows (no dead gap, #625).
//   2. Changing the available height (keybar toggle, the same lever every
//      viewport change pulls) REFLOWS the terminal AND sends a NEW PTY resize to
//      the task host with the new rows (#600). The PWA does exactly this
//      (fitAddon.fit() + ws.send(resize)) on every viewport change.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';

import 'support/connect_helpers.dart';

/// One captured PTY resize command (cols x rows) sent UI→task.
class _Resize {
  const _Resize(this.cols, this.rows);
  final int cols;
  final int rows;
  @override
  String toString() => '${cols}x$rows';
}

/// Wraps the real gateway and records every `resize` command sent UI→task —
/// the exact signal that re-sizes the remote PTY (session_host.dart →
/// `shell.resize`). Lets the test prove the server is TOLD the new size on a
/// viewport change, not just that the local widget reflowed.
class _ResizeSpyGateway implements TaskSshGateway {
  _ResizeSpyGateway(this._delegate);

  final TaskSshGateway _delegate;
  final List<_Resize> resizes = <_Resize>[];

  void clear() => resizes.clear();

  @override
  void send(Map<String, dynamic> payload) {
    if (payload['kind'] == 'resize') {
      resizes.add(_Resize(payload['cols'] as int, payload['rows'] as int));
    }
    _delegate.send(payload);
  }

  @override
  Stream<Map<String, dynamic>> get incoming => _delegate.incoming;

  @override
  void markServiceStopped() => _delegate.markServiceStopped();

  @override
  Future<void> dispose() => _delegate.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'terminal fills on first connect (no dead gap) and reflows + re-sends '
    'PTY resize on a viewport change',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final spy = _ResizeSpyGateway(FlutterForegroundSshGateway());
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(spy)],
      );
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

      // Reach the terminal screen, accepting the host-key prompt if shown.
      var connected = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final accept = find.text('Trust + connect');
        if (accept.evaluate().isNotEmpty) {
          await tester.tap(accept.first);
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (find
            .byKey(const Key('session-menu-button'))
            .evaluate()
            .isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(connected, isTrue, reason: 'never reached the terminal screen');

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final terminal = entry!.terminal;

      // Let the first connect + first frame + font load settle.
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // ── (1) #625 — the terminal FILLS the viewport on first connect. ──────
      // The default Terminal is 80x24. On a phone-class emulator screen the
      // terminal must fit MANY more than 24 rows. A terminal stuck at ~24 rows
      // is the dead-gap bug. We use a conservative floor (> 30) so the assertion
      // is robust across emulator densities while still failing the stuck-at-24
      // regression.
      final firstRows = terminal.viewHeight;
      debugPrint('LAYOUT625 firstFill ${terminal.viewWidth}x$firstRows');
      expect(
        firstRows,
        greaterThan(30),
        reason:
            'terminal did not fill the viewport on first connect — only '
            '$firstRows rows. This is the #625 dead-gap (stale first-frame '
            'size that never re-measured).',
      );

      // A resize matching the rendered size must have reached the host.
      expect(
        spy.resizes,
        isNotEmpty,
        reason: 'no PTY resize was ever sent to the host',
      );
      expect(
        spy.resizes.last.rows,
        firstRows,
        reason:
            'the last PTY resize ${spy.resizes.last} disagrees with the '
            'rendered $firstRows rows — server/client size diverged (#600)',
      );

      // ── (2) #600 — a viewport change REFLOWS + re-sends the PTY size. ─────
      // Toggling the keybar OFF frees ~one keybar of height; the terminal must
      // grow (more rows) AND a fresh resize must reach the host. This is the
      // same lever every viewport change pulls (keyboard show/hide, rotation).
      spy.clear();
      container.read(keybarVisibleProvider.notifier).toggle();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final grownRows = terminal.viewHeight;
      debugPrint(
        'LAYOUT600 afterKeybarToggle ${terminal.viewWidth}x$grownRows',
      );
      expect(
        grownRows,
        greaterThan(firstRows),
        reason:
            'hiding the keybar did not reflow the terminal (still $grownRows '
            'rows vs $firstRows) — viewport change did not re-fit (#600)',
      );
      expect(
        spy.resizes,
        isNotEmpty,
        reason:
            'viewport change reflowed the widget but sent NO PTY resize — the '
            'server now disagrees with the rendered size (#600)',
      );
      expect(
        spy.resizes.last.rows,
        grownRows,
        reason:
            'the resize sent after the viewport change (${spy.resizes.last}) '
            'disagrees with the rendered $grownRows rows (#600)',
      );
    },
  );
}
