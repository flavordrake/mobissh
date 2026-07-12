// On-emulator acceptance for #1069 (owner P0) — the ACCUMULATION test.
//
// An in-place-repainting TUI (Claude Code redrawing a status row with cursor
// addressing + `\x1b[2K`) OVERWRITES cells at FIXED absolute rows every frame,
// some frames carrying a URL and some plain text (the owner's `all-memories` /
// `usage-ledger` / `manual mode on`). The #1044 retained-match scan cache kept
// old matches whose cells had since been overwritten, so their washes piled up
// over text that no longer held the payload. The rollback restores the pre-#1044
// SYNCHRONOUS prune (#873): a match whose anchored cells no longer carry its
// payload is evicted the same frame — no accumulation.
//
// This drives a REAL SSH → shell → flterm chain and runs a remote loop that
// repaints ONE fixed row in place, alternating a UNIQUE URL with plain text.
// THE assertion, every frame: no visible wash sits over cells that do not hold
// its payload (`_driftedWashes` empty) — a stale/accumulated wash over the plain
// text would trip it. Holds a MID-CHURN window for an external screenshot.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/wash_no_accumulation_1069_shot_test.dart
// Screenshots: fire scripts/emu-shot.sh while a *_WINDOW_OPEN marker is logged.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

/// Every ON-SCREEN capsule wash cell-run that sits over cells NOT holding (part
/// of) its payload, at [offset]. Empty == every visible wash is on its glyphs —
/// no stale/accumulated wash over overwritten text (the #1069 guarantee).
List<String> _driftedWashes(TerminalController c, int offset) {
  final visible = c.scrollbar.visible;
  final out = <String>[];
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    final payload = '${r.payload}';
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : rowText.length;
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = (e > s ? rowText.substring(s, e) : '').trim();
      final onGlyph = slice.isNotEmpty &&
          (payload.contains(slice) || slice.contains(payload));
      if (!onGlyph) out.add('view=$viewRow "$slice" payload=$payload');
    }
  }
  return out;
}

bool _urlWashVisible(TerminalController c) => c.highlights
    .any((r) => r.capsule && '${r.payload}'.contains('example.com/live'));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an in-place repainting TUI never accumulates washes — no visible wash '
    'sits over overwritten (non-pattern) text at any churn frame (#1069)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(detectionSettingsProvider.notifier).setEnabled(true);

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

      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = ctrlOf();
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // Remote in-place repaint loop: overwrite ONE fixed row (row 6), ALTERNATING
      // a UNIQUE URL with the owner's exact plain-text tokens. Cursor addressing +
      // `\x1b[2K`, NO newline → the row is rewritten in place and the viewport
      // never scrolls (append-stable rows, the frame the #1044 cache wrongly
      // trusted). Each tick dwells 0.6s — comfortably past the 120ms discovery
      // debounce, so a URL tick reliably anchors a wash, and the very NEXT tick
      // overwrites those cells with `all-memories ...`: a retained (accumulated)
      // URL wash would then sit over that plain text (the #1069 bug).
      entry.proxy.sendInput(Uint8List.fromList(utf8.encode(
        'clear; for i in \$(seq 1 18); do '
        'if [ \$((i % 2)) -eq 0 ]; then '
        'printf "\\033[6;1H\\033[2Kopen https://example.com/live/\$i now"; '
        'else '
        'printf "\\033[6;1H\\033[2Kall-memories usage-ledger manual mode on \$i"; '
        // The DONE marker is split across two adjacent shell string literals so
        // the PTY-echoed command line does NOT contain the contiguous token —
        // only the printf OUTPUT does — otherwise the echo trips the done-check
        // on the first sample and the churn window closes immediately.
        'fi; sleep 0.6; done; printf "\\033[20;1H\\033[2KDONE""1069\\n"\n',
      )));

      TerminalController c() => controller!;
      var driftFrames = 0;
      var urlWashFrames = 0;
      final driftSamples = <String>[];

      Future<void> sample(String phase) async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        c().reportPaintedViewportOffset(c().scrollbar.offset);
        final drift = _driftedWashes(c(), c().paintedViewportOffset);
        if (drift.isNotEmpty) {
          driftFrames++;
          if (driftSamples.length < 8) driftSamples.add('[$phase] $drift');
        }
        if (_urlWashVisible(c())) urlWashFrames++;
      }

      // ---- Churn window: sample across the whole remote loop (~9s). ----
      debugPrint('WASH1069_MIDCHURN_WINDOW_OPEN');
      var done = false;
      for (var f = 0; f < 220 && !done; f++) {
        await sample('churn$f');
        await tester.pump(const Duration(milliseconds: 50));
        if (utf8.decode(out, allowMalformed: true).contains('DONE1069')) {
          done = true;
        }
      }
      debugPrint('WASH1069_MIDCHURN_WINDOW_CLOSED');
      expect(done, isTrue, reason: 'the remote repaint loop never finished');

      // Settle and re-check at rest.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      c().reportPaintedViewportOffset(c().scrollbar.offset);
      final settledDrift = _driftedWashes(c(), c().paintedViewportOffset);

      // THE #1069 assertion: at NO churn frame — and not at rest — did a wash
      // sit over cells that no longer hold its payload (no accumulation).
      expect(driftFrames, 0,
          reason: 'a wash sat over overwritten (non-pattern) text — the #1069 '
              'accumulation. Samples: $driftSamples');
      expect(settledDrift, isEmpty,
          reason: 'a stale wash lingered after the churn settled: $settledDrift');
      // Non-vacuous: detection WAS active — a URL wash appeared on many ticks.
      expect(urlWashFrames, greaterThan(3),
          reason: 'no URL wash ever appeared during the loop — the acceptance '
              'is vacuous (detection never ran)');
      debugPrint('WASH1069 pass: driftFrames=$driftFrames urlWashFrames='
          '$urlWashFrames (no wash ever over overwritten text)');

      // Settled hold for a stationary reference screenshot — row 6 holds the
      // final plain text, no stale URL wash anywhere.
      debugPrint('WASH1069_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      debugPrint('WASH1069_SETTLED_WINDOW_CLOSED');
    },
  );
}
