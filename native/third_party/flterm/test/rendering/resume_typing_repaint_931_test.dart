@Tags(['ffi'])
library;

// #931 (P0, device 0.1.10+68, detect-URLs ON = DEFAULT) — on a PRIMARY-screen
// in-place cursor-addressed redraw (huge catted page, heavy reflow) the terminal
// STOPS repainting on (a) app RESUME (return from another Android app) and (b)
// TYPING. Bytes arrive (telemetry: resume-liveness alive(fresh-bytes)) but the
// screen stays stale. This is NOT a +67/+68 regression — the paint machinery is
// byte-identical to +66; a different content shape exposed two paths #921 never
// covered. The structural cure (a non-consuming detection read) is #922; this is
// the TACTICAL fix on the existing #918/#921 seams.
//
// TWO GAPS (#921 widened the full-re-read gate, terminal_renderer.dart:754, but):
//
//   GAP 1 — RESUME forces a repaint via FOCUS-cycle only. On resume the host
//   widget cycles focus (unfocus → requestFocus next frame), which fires flterm's
//   `_onRenderObserverChanged` → `markNeedsPaint()` ONLY. It does NOT set
//   `_needsFrameSync` and does NOT `markAllRowsDirty()`. So when a prior
//   (detection-driven) sync already consumed the per-row damage, the resume
//   `_syncFrameState` runs with NOTHING dirty → the partial build re-reads ZERO
//   rows → the stale buffer repaints. The fix pairs the focus cycle with a real
//   `forceRepaint()` (markAllRowsDirty + frame-dirty) so resume re-reads the full
//   visible grid.
//
//   GAP 2 — the resilience of `_detectionActive` across an offstage→active /
//   resize-resync transition. The host applies `_applyDetectionActive` once at
//   init; a box that becomes visible later can be left `_detectionActive=false`.
//   Asserted via the `detectionActive` setter self-heal (a fresh full re-read on
//   the turn-on).
//
// The DETERMINISTIC repro of the consumed-damage freeze lives at the pipeline
// level (mirroring detection_consumes_damage_921_test.dart): a render-box harness
// cannot reproduce the cross-frame libghostty-handle consume because flterm's
// `_dirtyRows` marks are STICKY and survive a frame straddle. The render-box
// tests below assert the SEAM behaviour (forceRepaint re-reads + coalesces, the
// turn-on self-heals, idle never free-runs); the pipeline tests assert the
// consumed-damage correctness the resume/typing fix relies on.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/rendering.dart';
import 'package:flterm/src/rendering/atlas/atlas.dart';
import 'package:flterm/src/rendering/paint_state.dart';
import 'package:flterm/src/rendering/terminal_render_cache.dart';
import 'package:flterm/src/rendering/terminal_render_pipeline.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

import 'helpers/font_loader.dart';

void main() {
  setUpAll(loadBundledFonts);

  const cols = 16;
  const rows = 4;
  const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

  void writeUtf8(Terminal terminal, String text) {
    terminal.write(Uint8List.fromList(utf8.encode(text)));
  }

  // An in-place primary-screen rewrite (cursor-addressed cells only, ESC[r;cH +
  // ESC[K). libghostty reports per-row damage — the path a streaming cursor-
  // addressed redraw of a catted page takes. No alt-screen (no \x1b[?1049h).
  void inPlaceRedraw(Terminal terminal, String tag) {
    for (var r = 1; r <= rows; r++) {
      writeUtf8(terminal, '\x1b[$r;1H\x1b[Kprimary $tag row $r');
    }
  }

  // ---------------------------------------------------------------------------
  // GAP 1 + GAP 2 correctness — PIPELINE level (deterministic consumed-damage).
  // ---------------------------------------------------------------------------
  group('#931 consumed-damage on RESUME / TYPING (pipeline, deterministic)', () {
    AtlasConfig config() => AtlasConfig(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          fontFamily: 'monospace',
          fontFamilyFallback: const [],
          metrics: metrics,
          devicePixelRatio: 1.0,
        );

    late Terminal terminal;
    late Atlas atlas;
    late TerminalPaintState state;
    late TerminalRenderPipeline pipeline;

    setUp(() {
      terminal = Terminal(cols: cols, rows: rows);
      atlas = Atlas(config());
      state = TerminalPaintState(TerminalTheme.dark(), metrics)
        ..cols = cols
        ..rows = rows;
      pipeline = TerminalRenderPipeline(
        atlas: atlas,
        state: state,
        onImageReady: () {},
      )..configureGrid(rows, cols);
    });

    tearDown(() {
      pipeline.dispose();
      atlas.dispose();
      terminal.dispose();
    });

    test(
      '#922 STRUCTURAL: RESUME via a plain terminalDirty sync (no forceRepaint) '
      'after a prior detection sync consumed the damage STILL re-reads the full '
      'grid — the carry-forward self-heals the GAP 1 freeze (was 0 before #922)',
      () {
        expect(terminal.activeScreen, TerminalScreen.primary);

        // Content drawn + painted before backgrounding.
        inPlaceRedraw(terminal, 'A');
        pipeline.sync(terminal, terminalDirty: true);

        // Backgrounded: new content B arrives; a prior (detection-driven) sync
        // consumes the per-row damage.
        inPlaceRedraw(terminal, 'B');
        pipeline.sync(terminal, terminalDirty: true);

        // RESUME drives a terminalDirty sync that reads CLEAN (damage already
        // consumed). Before #922 the build was skipped → ZERO rows → stale. The
        // #922 `_damageUnsettled` carry-forward now forces a full re-read so the
        // resume paints the live grid even without the #931 forceRepaint pairing.
        pipeline.sync(terminal, terminalDirty: true);

        expect(
          pipeline.debugRowsRebuiltLastSync,
          equals(rows),
          reason: 'after #922 a resume sync that reads clean STILL re-reads the '
              'full visible grid — the consumed-damage freeze is structurally '
              'gone (the #931 forceRepaint is now belt-and-suspenders)',
        );
      },
    );

    test(
      'RESUME paired with forceRepaint (markAllRowsDirty) re-reads the FULL '
      'visible grid even when the damage was consumed — the GAP 1 fix',
      () {
        expect(terminal.activeScreen, TerminalScreen.primary);

        inPlaceRedraw(terminal, 'A');
        pipeline.sync(terminal, terminalDirty: true);

        inPlaceRedraw(terminal, 'B');
        pipeline.sync(terminal, terminalDirty: true);

        // The #931 fix: resume calls forceRepaint() → markAllRowsDirty before the
        // paint sync, so the build re-reads the full visible grid.
        pipeline.markAllRowsDirty();
        pipeline.sync(terminal, terminalDirty: true);

        expect(
          pipeline.debugRowsRebuiltLastSync,
          equals(rows),
          reason: 'resume paired with forceRepaint re-reads the full grid even '
              'when libghostty reports clean (the #931 GAP 1 fix)',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // SEAM behaviour — RENDER-BOX level.
  // ---------------------------------------------------------------------------
  group('#931 render-box seam (forceRepaint / detection self-heal / perf)', () {
    TerminalRenderCache createRenderCache() {
      final cache = TerminalRenderCache();
      addTearDown(cache.dispose);
      return cache;
    }

    Widget wrap(Terminal terminal, {TerminalRenderCache? renderCache}) {
      renderCache ??= createRenderCache();
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: cols * metrics.cellWidth,
              maxHeight: rows * metrics.cellHeight,
            ),
            child: TerminalRenderer(
              terminal: terminal,
              theme: TerminalTheme.dark(),
              metrics: metrics,
              offset: ViewportOffset.zero(),
              renderCache: renderCache,
              renderObserver: _TestRenderObserver(),
            ),
          ),
        ),
      );
    }

    late Terminal terminal;
    setUp(() => terminal = Terminal(cols: cols, rows: rows));
    tearDown(() => terminal.dispose());

    testWidgets(
      'GAP 1 wiring: the resume forceRepaint seam re-reads the FULL visible grid '
      'and increments the forced-repaint count (a real frame-sync, not just '
      'markNeedsPaint)',
      (tester) async {
        await tester.pumpWidget(wrap(terminal));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        box.detectionActive = true;
        await tester.pump();
        expect(terminal.activeScreen, TerminalScreen.primary);

        inPlaceRedraw(terminal, 'A');
        await tester.pump();
        inPlaceRedraw(terminal, 'B');
        await tester.pump();

        final forcedBefore = box.debugForceRepaintCount;
        box.forceRepaint();
        await tester.pump();

        expect(box.debugForceRepaintCount, greaterThan(forcedBefore),
            reason: 'resume triggers a real frame-sync (forceRepaint)');
        expect(box.debugRowsRebuiltLastSync, rows,
            reason: 'resume re-reads the full visible grid');
      },
    );

    testWidgets(
      'GAP 2 self-heal: turning detectionActive ON forces a fresh full re-read '
      '(an offstage→active box left false must self-heal on apply)',
      (tester) async {
        await tester.pumpWidget(wrap(terminal));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        // Box starts with detection OFF (the offstage-at-init case).
        expect(box.debugDetectionActive, isFalse);

        inPlaceRedraw(terminal, 'A');
        await tester.pump();

        // Late detection apply (re-applied after the box became visible / the
        // resize-resync settled). The setter must self-heal with a full re-read.
        box.detectionActive = true;
        await tester.pump();

        expect(box.debugDetectionActive, isTrue);
        expect(box.debugRowsRebuiltLastSync, rows,
            reason: 'turning detection ON self-heals with a full visible-grid '
                're-read (#931 GAP 2 offstage→active resilience)');
      },
    );

    testWidgets(
      '#918 REGRESSION GUARD: many forces within ONE frame coalesce to exactly '
      'one forced re-snapshot (with detection active)',
      (tester) async {
        await tester.pumpWidget(wrap(terminal));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        box.detectionActive = true;
        await tester.pump();
        final before = box.debugForceRepaintCount;

        for (var i = 0; i < 5; i++) {
          box.forceRepaint();
        }
        await tester.pump();

        expect(box.debugForceRepaintCount - before, 1,
            reason: 'multiple forces in one frame coalesce to one (#918)');
      },
    );

    testWidgets(
      '#805 PERF GUARD: with detection active but NO input, NO output, NO resume '
      'the settle tick never arms and there are zero forced repaints',
      (tester) async {
        final scheduled = <void Function()>[];
        await tester.pumpWidget(wrap(terminal));
        await tester.pump(const Duration(milliseconds: 200));
        final box = tester.renderObject<TerminalRenderBox>(
          find.byType(TerminalRenderer),
        );
        box.detectionActive = true;
        await tester.pump(const Duration(milliseconds: 200));
        box.debugSetOutputSettleTickFactory(
          (_, cb) {
            scheduled.add(cb);
            return Timer(const Duration(days: 1), () {})..cancel();
          },
        );
        final forcedBefore = box.debugForceRepaintCount;

        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(box.debugOutputTickArmed, isFalse,
            reason: 'idle never arms the tick even with detection active');
        expect(scheduled, isEmpty,
            reason: 'idle schedules no settle timer (no free-run)');
        expect(box.debugForceRepaintCount, forcedBefore,
            reason: 'idle produces zero forced repaints (#805 battery guard)');
      },
    );
  });
}

class _TestRenderObserver implements TerminalRenderObserver {
  @override
  TerminalSelection? get selection => null;

  @override
  bool get hasFocus => true;

  @override
  List<HighlightRange> get highlights => const [];

  @override
  void reportPaintedViewportOffset(int offset) {}

  @override
  bool get isScrolling => false;

  @override
  bool get contentSettling => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
