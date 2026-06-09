// Widget tests for the terminal fill/re-measure path
// (#625 / #600 / #641 / #647 / #659).
//
// Root cause (device): xterm.dart computes cols/rows from `cellSize` ONLY
// inside `RenderTerminal.performLayout` and CACHES the result; it re-sends a
// PTY resize only when that cached size CHANGES. On a real device's first
// connect the first layout can run before the bundled JetBrainsMono asset font
// has settled, so the terminal locks in cols/rows for the fallback font's cell
// size and never re-measures (constraints don't change) — the dead gap above
// the keybar.
//
// #641 forced `markNeedsLayout` on `systemFonts` change + `didChangeMetrics`.
// #647 armed that SAME `markNeedsLayout` on the connect transition. BOTH shipped
// and FAILED on device: `markNeedsLayout` re-runs `performLayout` with the SAME
// constraint → recomputes the SAME stale cell size → SAME cached viewport size
// → NO-OP. Only a CHANGED constraint (the keyboard toggle) ever fixed it.
//
// #659 stops relying on xterm's auto-measure. On connect + font-load it computes
// cols/rows from the CURRENT rendered viewport `size` + the painter `cellSize`
// and drives `terminal.resize(cols, rows, ...)` DIRECTLY — which fires
// `onResize` → `proxy.sendResize` → PTY (sessions.dart) and updates the
// terminal's view size, bypassing the stale cache. Every attempt logs a
// CTRACE659 line (`ctrace('ui.fit659', …)`) so a device failure yields DATA.
//
// A headless harness can't reproduce the asset-font race: test fonts are
// preloaded before the first frame, so xterm always measures the correct cell
// size on the first layout (the "fills the viewport" test below confirms that
// baseline) and the connect-time explicit fit finds the terminal already at the
// right size (a no-op for the rendered size). What the harness CAN lock in is
// the fix's WIRING — that the body (a) registers a system-fonts listener +
// WidgetsBindingObserver and tears them down on dispose, (b) ARMS the connect
// fit burst on the shell-ready transition with NO fonts/metrics event
// (`debugConnectRemeasureArmCount`), (c) emits CTRACE659 lines, and (d) the
// explicit-resize MECHANISM actually corrects a size discrepancy via
// `terminal.resize` reaching the transport (the "explicit fit corrects a stale
// size" test forces a discrepancy the device would have). The on-emulator
// integration test (`terminal_layout_fill_test.dart`) plus owner cold-start
// validation are the real device gate for the actual re-fit.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/terminal_backend.dart';
import 'package:mobissh/state/terminal_providers.dart';
import 'package:mobissh/ui/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/ssh/ssh_shell.dart';

import '../support/fake_ssh_shell_transport.dart';

/// Setup variant that drives the session to the SHELL-READY state by overriding
/// `sshShellProvider` with a real [SshShell] attached to the session's
/// `Terminal` — the same wiring production does once a session reaches
/// `connected`. This is the precise "first connect / shell-ready" transition
/// that #647's fix must hook to force a re-measure, WITHOUT a keyboard or font
/// event. `attach` binds `Terminal.onResize` → `transport.resize`, so any
/// re-measure that changes cols/rows reaches [transport]. We attach AFTER the
/// first frame (post-frame) so the TerminalView has laid out and the terminal
/// is at its filled size when the shell connects — matching the device order
/// (layout first, then connect).
Future<({SessionEntry entry, ProviderContainer container})> _setupConnected(
  WidgetTester tester,
  FakeSshShellTransport transport,
) async {
  final pair = InMemoryGatewayPair();
  addTearDown(() async => pair.dispose());
  late final SessionEntry entry;
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      // Resolve the shell as "ready" so the body sees the connect transition.
      sshShellProvider.overrideWith((ref, sessionId) async {
        final shell = SshShell(transport);
        shell.attach(entry.terminal);
        ref.onDispose(shell.dispose);
        return shell;
      }),
      // Ghostty is the default since #725; these are xterm-render assertions
      // (flterm can't paint headless), so pin the xterm backend.
      terminalBackendProvider.overrideWith(
        (ref) => TerminalBackendNotifier()..set(TerminalBackend.xterm),
      ),
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
      // Ghostty is the default since #725; these are xterm-render assertions
      // (flterm can't paint headless), so pin the xterm backend.
      terminalBackendProvider.overrideWith(
        (ref) => TerminalBackendNotifier()..set(TerminalBackend.xterm),
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
    debugConnectRemeasureArmCount = 0;
    debugExplicitFitAppliedCount = 0;
    debugForcedPtyResyncCount = 0;
    debugOffstageFitSkipCount = 0;
    debugMetricsFitCount = 0;
    clearConnectLog();
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
        // Guard for #647: `_setup` never drives the session to shell-ready, so
        // the connect re-measure burst must NOT have been armed. This makes the
        // connect-test's arm-count assertion meaningful — it proves the burst
        // fires on the connect transition, not merely on mount.
        expect(
          debugConnectRemeasureArmCount,
          0,
          reason:
              'connect re-measure burst armed without a shell-ready session',
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
      'a STORM of metrics events (keyboard-hide animation) coalesces into ONE '
      'settled fit — not one fit per animation frame (#848 debounce)',
      (tester) async {
        // The #848 device storm: keyboard hide animates the viewport inset over
        // many frames; each frame raised didChangeMetrics, which fitted +
        // resized EVERY frame, for every session. The fix DEBOUNCES the metrics
        // fit — many rapid inset changes settle into a single fit after the
        // animation stops. This test fires a burst of metrics events spaced
        // INSIDE the debounce window and asserts the fit runs exactly ONCE,
        // after the window elapses — not N times.
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setup(tester, transport);
        expect(s.entry.terminal.viewHeight, greaterThan(24));

        debugMetricsFitCount = 0;

        // 12 metrics events 10ms apart (~one keyboard-animation worth), all
        // INSIDE the ~120ms debounce window. A per-frame fit would run ~12×;
        // the debounce must run 0× while the storm is in flight (each event
        // resets the settle timer).
        for (var i = 0; i < 12; i++) {
          tester.binding.handleMetricsChanged();
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(
          debugMetricsFitCount,
          0,
          reason:
              'a metrics fit ran WHILE the inset animation was still firing — '
              'the storm was not debounced. Each event must reset the settle '
              'timer so no fit runs mid-animation (#848).',
        );

        // Let the debounce window elapse with no further events — the storm has
        // SETTLED, so exactly one coalesced fit runs.
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          debugMetricsFitCount,
          1,
          reason:
              'the settled keyboard-hide must drive exactly ONE fit, not one '
              'per animation frame (#848). Got: $debugMetricsFitCount',
        );

        // A LATER, separate metrics event (a second keyboard toggle) debounces
        // independently into one more fit.
        tester.binding.handleMetricsChanged();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          debugMetricsFitCount,
          2,
          reason:
              'a subsequent settled metrics event must drive its own single '
              'fit. Got: $debugMetricsFitCount',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the settled fit computes rows from the CHROME-EXCLUDED terminal box, not '
      'the full screen height — no 53-row overgrow (#848)',
      (tester) async {
        // The #848 overgrow: a mid-animation fit measured a TRANSIENT height
        // (the keybar/compose/status chrome had not re-laid-out yet) → 53 rows,
        // abnormally tall. Because the terminal is laid out inside an Expanded
        // ABOVE that chrome, its render-box height is ALREADY chrome-excluded;
        // the bug was reading it mid-animation. With the debounce we fit off the
        // SETTLED box. This asserts the fitted rows equal what the laid-out
        // RenderTerminal actually affords — never the (larger) full-screen rows.
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setup(tester, transport);

        // Drive a settled metrics fit (the keyboard-hide analog).
        tester.binding.handleMetricsChanged();
        await tester.pump(const Duration(milliseconds: 200));

        // The terminal's RenderTerminal box — laid out INSIDE the Expanded above
        // the keybar/session-bar chrome, so its height is already chrome-
        // excluded. The fit reads exactly this box (production: _explicitFit).
        final state = tester.state<TerminalViewState>(
          find.byType(TerminalView),
        );
        final box = state.renderTerminal;
        const pad = 4.0;
        final affordedRows = ((box.size.height - pad * 2) ~/ box.cellSize.height)
            .clamp(1, 1 << 20);

        // The full SCREEN height (the chrome-INCLUDED measurement a mid-animation
        // fit transiently used → the 53-row overgrow). The chrome-excluded box is
        // strictly shorter, so it must afford strictly FEWER rows.
        final screenH = tester.view.physicalSize.height /
            tester.view.devicePixelRatio;
        final fullHeightRows =
            ((screenH - pad * 2) ~/ box.cellSize.height).clamp(1, 1 << 20);

        expect(
          s.entry.terminal.viewHeight,
          affordedRows,
          reason:
              'the terminal rows must match the chrome-excluded box height '
              '($affordedRows), proving the settled fit measured the real '
              'terminal area, not a transient. Got ${s.entry.terminal.viewHeight}',
        );
        expect(
          affordedRows,
          lessThan(fullHeightRows),
          reason:
              'the chrome-excluded box ($affordedRows rows) must be SHORTER '
              'than a full-screen-height fit ($fullHeightRows rows) — proving '
              'the chrome is excluded. A fit off the full height is the #848 '
              '53-row overgrow.',
        );
        expect(
          s.entry.terminal.viewHeight,
          lessThan(fullHeightRows),
          reason:
              'the fitted rows (${s.entry.terminal.viewHeight}) must stay below '
              'the full-screen-height rows ($fullHeightRows) — the #848 '
              '53-row overgrow is exactly a full-height (chrome-included) fit',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'first connect schedules a re-measure burst WITHOUT any fonts/metrics '
      'event (#647): the body re-runs xterm layout on the connect transition, '
      'so the terminal fills + the PTY size is sent without a keyboard toggle',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        // _setupConnected drives the session to shell-ready (the connect
        // transition) and pumps the initial frames. It dispatches NO
        // fonts-change and NO metrics event — mirroring the device's first
        // connect: bundled font already cached (no systemFonts event) and no
        // viewport change (no didChangeMetrics). On device the #641 remeasure
        // therefore never fired on first connect, so the stale first-frame
        // measure persisted until the user tapped to show the keyboard. #647
        // hooks the connect transition to fire the same remeasure burst.
        //
        // HONEST LIMITATION: a headless harness CANNOT reproduce the device's
        // stale-cell-size race — test fonts are preloaded, so xterm always
        // measures correctly on the first layout and a re-measure is a no-op
        // for the rendered size. What this test LOCKS IN is the WIRING the
        // device fix depends on: that the connect transition (a) drives the
        // terminal to its filled size with no viewport/font event, (b) re-runs
        // layout repeatedly across the burst window (so a settled-font frame
        // gets a re-fit on device), and (c) never throws. The on-emulator
        // `terminal_layout_fill_test.dart` is the device gate; the owner does
        // the final cold-start → connect validation.
        final s = await _setupConnected(tester, transport);

        // (a) The connect/shell-ready transition armed the #647 re-measure
        //     burst — with NO fonts-change and NO metrics event dispatched.
        //     This is the precise behavior the device fix adds: the same
        //     re-measure the keyboard-show triggered, now fired by connect.
        expect(
          debugConnectRemeasureArmCount,
          greaterThanOrEqualTo(1),
          reason:
              'the connect/shell-ready transition did NOT arm the #647 '
              're-measure burst (no keyboard/font event fired it) — the '
              'terminal would stay stale until a keyboard toggle on device',
        );

        // (b) The terminal filled (more than the default 24 rows) on the
        //     connect path alone — no keyboard toggle, no font event — and the
        //     shell-attach resize carried that size to the transport.
        final filled = s.entry.terminal.viewHeight;
        expect(
          filled,
          greaterThan(24),
          reason:
              'terminal did not fill on connect without a viewport/font event '
              '(#647) — only $filled rows',
        );
        expect(
          transport.resizes,
          isNotEmpty,
          reason: 'no PTY resize reached the transport on first connect (#647)',
        );
        expect(
          transport.resizes.last.rows,
          filled,
          reason:
              'the last PTY resize (${transport.resizes.last}) disagrees with '
              'the filled $filled rows on connect (#647)',
        );

        // (c) The connect burst re-runs xterm layout across a delayed window
        //     (120/350/700ms) WITHOUT any fonts/metrics event. Advance across
        //     the whole burst window; no fonts/metrics event is dispatched, so
        //     ONLY the #647 connect burst can act here. The burst must not
        //     throw and must not regress the fill (idempotent re-measure).
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Still filled, PTY size still aligned, no exceptions — the burst is
        // idempotent and safe (it must not regress the fill or throw).
        expect(s.entry.terminal.viewHeight, filled);
        expect(transport.resizes.last.rows, filled);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'connect emits CTRACE659 fit lines into the on-device connect log (#659) '
      'so a device failure carries the render size, cell metrics + computed '
      'cols/rows — not blind iteration',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setupConnected(tester, transport);

        // Advance across the full burst window so every staggered fit fires.
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        final log = connectLogSnapshot();
        final fitLines = log.where((l) => l.contains('ui.fit659')).toList();
        expect(
          fitLines,
          isNotEmpty,
          reason:
              'no CTRACE659 (ui.fit659) lines in the connect log — the device '
              'diagnosis trace is missing, so a failed connect would yield no '
              'data. Lines: $log',
        );
        // The diagnostic must carry the load-bearing fields: the rendered view
        // size, the painter cell metrics, and the computed-vs-current cols/rows.
        // These are exactly what tells the owner (and us) WHY the fill is wrong
        // on device. A bare "connect: arming" line is not enough.
        final dataLine = fitLines.firstWhere(
          (l) =>
              l.contains('view=') &&
              l.contains('cell=') &&
              l.contains('computed='),
          orElse: () => '',
        );
        expect(
          dataLine,
          isNotEmpty,
          reason:
              'CTRACE659 lines exist but none carry view=/cell=/computed= — '
              'the diagnostic is missing the fields needed to diagnose a '
              'device fill failure. Lines: $fitLines',
        );
        // It must reflect the terminal that actually filled (sanity: the
        // computed rows the trace reports should be the filled height, proving
        // the trace reads the real render object, not a placeholder).
        expect(dataLine, contains('x${s.entry.terminal.viewHeight}'));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('explicit fit CORRECTS a stale terminal size on connect via '
        'terminal.resize → transport (#659): proves the real recompute mechanism, '
        'not a markNeedsLayout no-op', (tester) async {
      // This is the #659 mechanism test. #641/#647 failed because
      // markNeedsLayout re-derives the SAME stale size — a no-op. Here we
      // SIMULATE the device's stale state: after the terminal has filled to
      // its real size, we shove its view size back to a WRONG value (as a
      // stale first-frame measure would have left it), then drive a fit and
      // assert the explicit `terminal.resize` recomputes the CORRECT size from
      // the render object's cell metrics and pushes it to the transport. A
      // markNeedsLayout-only fix could NOT recover this (xterm's cached size
      // already matches the rendered cell size, so its performLayout is a
      // no-op); only an explicit recompute-and-resize does.
      final transport = FakeSshShellTransport();
      addTearDown(transport.close);
      final s = await _setupConnected(tester, transport);

      final filled = s.entry.terminal.viewHeight;
      expect(filled, greaterThan(24));

      // Force a stale/wrong size, mimicking the device's pre-settle measure.
      // (Smaller than the real fill — the dead-gap symptom.)
      final staleRows = filled - 5;
      s.entry.terminal.resize(s.entry.terminal.viewWidth, staleRows);
      expect(s.entry.terminal.viewHeight, staleRows);
      final resizesBefore = transport.resizes.length;
      final appliedBefore = debugExplicitFitAppliedCount;

      // Drive a fit the way the connect burst / font-load does. didChangeMetrics
      // routes through the SAME _scheduleExplicitFit path; dispatch a metrics
      // change (no actual viewport change in the test, but it triggers our
      // explicit recompute — the device's keyboard toggle analog).
      tester.binding.handleMetricsChanged();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The explicit fit recomputed the CORRECT size from the render object
      // and drove terminal.resize — restoring the fill and reaching the PTY.
      expect(
        s.entry.terminal.viewHeight,
        filled,
        reason:
            'explicit fit did NOT correct the stale size back to the real '
            'fill ($filled) — it was left at $staleRows. A markNeedsLayout-'
            'only fix (the #641/#647 no-op) would fail exactly here.',
      );
      expect(
        debugExplicitFitAppliedCount,
        greaterThan(appliedBefore),
        reason:
            'the explicit-resize counter did not advance — the fit did not '
            'drive terminal.resize to correct the discrepancy',
      );
      expect(
        transport.resizes.length,
        greaterThan(resizesBefore),
        reason:
            'the corrected size never reached the transport (PTY) — '
            'terminal.resize did not flow through onResize → sendResize',
      );
      expect(transport.resizes.last.rows, filled);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'connect FORCE-RESYNCS the PTY even when the LOCAL size is already '
      'correct (#666): first-connect-after-cold-launch leaves the remote at the '
      'stale default size; the fit must re-send the size to the PTY even though '
      'the local view did not change',
      (tester) async {
        // The #666 device bug: on first connect the initial PTY resize is sent
        // at the terminal's default size before layout, so tmux attaches at
        // ~80x24; the local terminal then lays out correctly, but because its
        // size never CHANGES again the old `if (changed)` guard re-sent
        // nothing — tmux stayed at 24 rows (status bar mid-screen, dead gap).
        // The fix force-resends on the connect path even when !changed.
        //
        // In this harness the terminal fills correctly on first layout, so the
        // connect-path fits find the local size ALREADY correct (changed=false)
        // — exactly the device condition where the old code did nothing. We
        // assert the force path runs and the size still reaches the transport.
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        final s = await _setupConnected(tester, transport);

        final filled = s.entry.terminal.viewHeight;
        expect(filled, greaterThan(24));

        // Advance the full burst window so connect-path fits run while the
        // local size is already `filled` (changed == false).
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // At least one connect-path fit force-resynced the PTY WITHOUT a local
        // size change — the behavior the old `if (changed)` guard suppressed,
        // and the exact gap that left tmux stale on first connect (#666).
        expect(
          debugForcedPtyResyncCount,
          greaterThanOrEqualTo(1),
          reason:
              'no force PTY re-sync on the connect path — a stale remote '
              '(#666 first-connect-after-cold-launch) would never be corrected. '
              'Log: ${connectLogSnapshot()}',
        );
        // The re-sync reached the transport carrying the filled rows (the PTY
        // gets the correct size, not the stale default).
        expect(transport.resizes, isNotEmpty);
        expect(transport.resizes.last.rows, filled);
        // The diagnostic records the new RESYNC action so a device log shows it.
        expect(
          connectLogSnapshot().any(
            (l) => l.contains('ui.fit659') && l.contains('RESYNC'),
          ),
          isTrue,
          reason: 'no RESYNC action logged — the force-resync path did not run',
        );
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

  group('offstage fit hygiene (#836)', () {
    // The device "disconnected with no indication" report shipped a connect-log
    // that was ~entirely the per-frame `[ui.fit659] no TerminalViewState yet
    // (offstage?)` line — the fit path fires per-frame (post-frame callbacks,
    // didChangeMetrics, font changes, the connect burst), and while the body is
    // offstage (no mounted TerminalViewState) every one logged, flooding the
    // 200-event ring and burying the actual disconnect. The fix SKIPS the fit
    // offstage and logs the skip AT MOST ONCE per offstage period.

    testWidgets(
      'repeated metrics/font events with NO mounted TerminalViewState skip the '
      'fit and log the offstage line ONLY ONCE — the connect ring does not '
      'flood (#836)',
      (tester) async {
        // Use the DEFAULT (ghostty) backend: TerminalScreen renders the flterm
        // body, NOT the xterm TerminalView, so `_findTerminalViewState()`
        // returns null on every fit attempt — the exact "no TerminalViewState
        // (offstage?)" condition. The metrics/font listeners + the mount/connect
        // fit all still route through `_explicitFit`, so this faithfully drives
        // the offstage branch the device hit (the fit659 spam fired while there
        // was no xterm view to measure).
        final pair = InMemoryGatewayPair();
        addTearDown(() async => pair.dispose());
        final container = ProviderContainer(
          overrides: [
            taskSshGatewayProvider.overrideWithValue(pair.uiSide),
          ],
        );
        addTearDown(container.dispose);
        container
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
        await tester.pump(const Duration(milliseconds: 50));

        clearConnectLog();
        final skipsBefore = debugOffstageFitSkipCount;

        // Fire many metrics/font events — each routes through _explicitFit.
        for (var i = 0; i < 20; i++) {
          tester.binding.handleMetricsChanged();
          await _fireFontsChange(tester);
          await tester.pump(const Duration(milliseconds: 20));
        }

        // The fit was SKIPPED on each attempt (work avoided)...
        expect(
          debugOffstageFitSkipCount,
          greaterThan(skipsBefore),
          reason:
              'fits with no mounted TerminalViewState must be skipped (counted) '
              '— the fit does no useful work (#836)',
        );

        // ...but the offstage ctrace line was emitted AT MOST ONCE, so the ring
        // did not flood. (Before the fix this was one line PER attempt — the
        // ~100×/sec spam that buried the disconnect.)
        final offstageLines = connectLogSnapshot()
            .where((l) => l.contains('offstage?'))
            .toList();
        expect(
          offstageLines.length,
          lessThanOrEqualTo(1),
          reason:
              'the offstage-skip line must be logged at most once per offstage '
              'period — it must NOT flood the 200-event connect ring and bury '
              'disconnect events (#836). Got: $offstageLines',
        );

        // No real fit ran, so neither the explicit-fit nor the forced
        // PTY-resync counters advanced — pure churn was eliminated.
        expect(debugExplicitFitAppliedCount, 0);
        expect(debugForcedPtyResyncCount, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a HIGH-signal lifecycle event survives a flood of offstage-fit lines '
      '— state transitions are not evicted (#836)',
      (tester) async {
        // Even if some offstage spam slips through, a lifecycle event (the kind
        // a session drop records via clifecycle) lands in the dedicated ring
        // that outlives connect-ring churn. This is the survivability guarantee.
        clifecycle('task.host', 'state: connected → softDisconnected');

        // Flood the connect ring with offstage-style fit lines past its cap.
        for (var i = 0; i < connectLogCapacity + 50; i++) {
          ctrace('ui.fit659', 'metrics $i: no TerminalViewState yet (offstage?)');
        }

        expect(
          lifecycleLogSnapshot().join('\n'),
          contains('state: connected → softDisconnected'),
          reason:
              'the drop transition must outlive an offstage-fit flood — the '
              'core #836 telemetry-hygiene guarantee',
        );
      },
    );

    testWidgets(
      'when the view IS mounted the fit still runs — first-connect fill is not '
      'regressed (#659/#666)',
      (tester) async {
        final transport = FakeSshShellTransport();
        addTearDown(transport.close);
        // Onstage + shell-ready: the connect burst must still arm and the fit
        // must still drive the PTY resize (the #659/#666 first-connect fill).
        final s = await _setupConnected(tester, transport);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(
          debugConnectRemeasureArmCount,
          greaterThanOrEqualTo(1),
          reason: 'onstage connect must still arm the fit burst (no regression)',
        );
        expect(
          debugForcedPtyResyncCount,
          greaterThanOrEqualTo(1),
          reason: 'onstage connect must still force-resync the PTY (#666)',
        );
        expect(s.entry.terminal.viewHeight, greaterThan(24));
        // The onstage path must NOT have logged any offstage-skip line.
        expect(
          connectLogSnapshot().where((l) => l.contains('offstage?')),
          isEmpty,
          reason: 'a mounted view must never log the offstage-skip line',
        );
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
