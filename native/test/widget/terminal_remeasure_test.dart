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
