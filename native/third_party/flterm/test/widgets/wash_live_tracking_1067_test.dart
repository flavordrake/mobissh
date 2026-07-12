@Tags(['ffi'])
library;

// #1067 (owner DEFINITIVE P0) — restore the ORIGINAL live-tracking wash and
// paint the text ON TOP. This SUPERSEDES the hide-on-scroll (#1062) / quiesce
// (#1064) / miss-grace (#1060) machinery, all of which HID the wash. The owner's
// spec: the wash is NEVER hidden; it TRACKS its token live every paint and the
// glyphs render on top (undimmed).
//
// The wash carries the anchor's ABSOLUTE buffer rows (the persistent #767 anchor
// set) and the HighlightPainter maps `viewRow = absRow - viewportOffset` against
// the SAME painted offset the glyphs use each frame — so it lands wherever the
// anchor CURRENTLY is, with no suppression gate.
//
// This test drives a REAL TerminalView through (a) a fling and (b) streaming
// content churn, and asserts PER FRAME:
//   * VISIBLE — whenever a capsule wash's row is on-screen the painter DREW it
//     (`renderBox.debugWashViewRows` is non-empty; never a hidden frame), AND
//   * LOCKSTEP — the exact set of painted wash viewport rows equals
//     `{ absRow - paintedViewportOffset }` for every on-screen anchor row, AND
//   * ON-GLYPH — every visible wash cell-run sits on its token's real glyphs.
// (Text-on-top / behind-glyph paint order is pinned by paint_order_1045_test.)

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The app paints a behind-glyph capsule wash for url / path anchors. Mirror it.
const _washPatternIds = {'url', 'path'};

HighlightStyle? _washResolver(StructuredMatch m) {
  if (!_washPatternIds.contains(m.patternId)) return null;
  return const HighlightStyle(background: Color(0x8800FF00), capsule: true);
}

/// The set of VIEWPORT rows every on-screen highlight range occupies at
/// [offset] — the LIVE-resolved rows the wash painter must have drawn this
/// frame. Mirrors the painter's own `absRow - offset` mapping and on-screen
/// clip, so an exact match proves per-frame lockstep with the anchors.
Set<int> _expectedWashViewRows(
    TerminalController c, int visibleRows, int offset) {
  final out = <int>{};
  for (final r in c.highlights) {
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visibleRows) continue;
      out.add(viewRow);
    }
  }
  return out;
}

/// Every ON-SCREEN capsule wash cell-run that currently sits over cells NOT
/// holding (part of) its payload, mapped at [offset]. Empty == every visible
/// wash is correctly on its token's glyphs.
List<String> _driftedWashes(TerminalController c, int cols, int offset) {
  final visible = c.scrollbar.visible;
  final out = <String>[];
  for (final r in c.highlights) {
    if (!r.capsule) continue;
    final payload = '${r.payload}';
    for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
      final viewRow = absRow - offset;
      if (viewRow < 0 || viewRow >= visible) continue;
      final startCol = absRow == r.topRow ? r.topCol : 0;
      final endCol = absRow == r.bottomRow ? r.bottomCol : cols;
      final rowText = c.visibleRowsText(viewRow, viewRow);
      final s = startCol.clamp(0, rowText.length);
      final e = endCol.clamp(0, rowText.length);
      final slice = (e > s ? rowText.substring(s, e) : '').trim();
      final onGlyph = slice.isNotEmpty &&
          (payload.contains(slice) || slice.contains(payload));
      if (!onGlyph) {
        out.add('abs=$absRow view=$viewRow "$slice" payload=$payload');
      }
    }
  }
  return out;
}

void main() {
  testWidgets(
    'the detection wash STAYS VISIBLE and tracks its token per-frame during a '
    'fling — never hidden, never a pinned/stale band (#1067)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      )
        ..registerTextPattern(TextPattern.url())
        ..registerTextPattern(TextPattern.path())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      final scrollController = TerminalScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 620,
              child: TerminalView(
                controller: controller,
                scrollController: scrollController,
                autofocus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      // A flood with a URL + a path anchor every 40 lines so a wash is on screen
      // at every fling position.
      for (var i = 0; i < 800; i++) {
        if (i % 40 == 0) {
          write('line ${i.toString().padLeft(5, '0')} '
              'https://example.com/page/$i and /etc/hosts/$i too\r\n');
        } else {
          write('line ${i.toString().padLeft(5, '0')} '
              'filler filler filler filler\r\n');
        }
      }
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 40 && controller.isScrolling; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();

      TerminalRenderBox renderBox() => tester.renderObject<TerminalRenderBox>(
            find.byType(TerminalRenderer),
          );

      final visibleRows = controller.scrollbar.visible;
      expect(controller.isScrolling, isFalse, reason: 'should be at rest');
      expect(
        controller.highlights.any((r) => r.capsule),
        isTrue,
        reason: 'precondition: a capsule wash is live before the fling',
      );

      // ---- the measured fling: 60 frames of pure viewport movement ----
      final position = scrollController.position;
      final startPixels = position.pixels;
      var framesWithVisibleWash = 0;
      for (var frame = 1; frame <= 60; frame++) {
        position.jumpTo(startPixels - frame * 40.0);
        await tester.pump(const Duration(milliseconds: 16));

        final offset = controller.paintedViewportOffset;
        final expected = _expectedWashViewRows(controller, visibleRows, offset);
        final painted = renderBox().debugWashViewRows.toSet();

        // LOCKSTEP: the painter resolved EXACTLY the on-screen anchor rows this
        // frame — no baked/stale range, no hidden frame.
        expect(
          painted,
          equals(expected),
          reason: 'frame $frame: painted wash rows $painted != live-resolved '
              '$expected (offset=$offset) — the wash is not tracking per-frame',
        );

        if (expected.isNotEmpty) {
          framesWithVisibleWash++;
          // VISIBLE: an on-screen wash was actually drawn (never hidden).
          expect(painted, isNotEmpty,
              reason: 'frame $frame: a wash was on-screen but the painter drew '
                  'nothing — the wash was HIDDEN (the #1067 regression)');
          // ON-GLYPH: it sits on its token's real cells.
          final drift = _driftedWashes(controller, 62, offset);
          expect(drift, isEmpty,
              reason: 'frame $frame: a visible wash sat off its token: $drift');
        }
      }

      // Non-vacuous: the fling actually kept a wash on screen for many frames.
      expect(framesWithVisibleWash, greaterThan(10),
          reason: 'the fling never had a visible wash — test is vacuous');

      // Drain the scroll-settle / detection debounce timers before teardown so
      // the framework's "no pending timers" invariant holds.
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 40 && controller.isScrolling; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 400));
      debugPrint('WASH1067 fling OK: framesWithVisibleWash='
          '$framesWithVisibleWash/60 (never hidden, per-frame lockstep)');
    },
  );

  testWidgets(
    'streaming content churn: whatever is anchored tracks per-frame with no '
    'stale/drifted wash, and once the stream SETTLES the last URL anchors on '
    'its token (debounced discovery — the #1069 rollback tradeoff)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      )
        ..registerTextPattern(TextPattern.url())
        ..registerTextPattern(TextPattern.path())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      final scrollController = TerminalScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 620,
              child: TerminalView(
                controller: controller,
                scrollController: scrollController,
                autofocus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      TerminalRenderBox renderBox() => tester.renderObject<TerminalRenderBox>(
            find.byType(TerminalRenderer),
          );

      final visibleRows = controller.scrollbar.visible;

      // ---- streaming churn: emit output continuously with a URL anchor in the
      // stream, so the grid rewrites/scrolls at the bottom every frame. #1069
      // rolled back the #1044 content-keyed scan cache (its retained matches were
      // the accumulation source). DISCOVERY is debounced (#767) with no max-wait
      // ceiling, so unbroken sub-debounce (16ms) streaming can DEFER anchoring
      // until the stream pauses — the sanctioned tradeoff (no retained cache =>
      // no accumulation; see wash_no_accumulation_1069_test). What MUST hold on
      // EVERY frame regardless: whatever IS anchored tracks its token in lockstep
      // and NO wash ever sits over cells that do not hold its payload. ----
      for (var frame = 1; frame <= 80; frame++) {
        if (frame % 3 == 0) {
          write('churn $frame visit https://example.com/live/$frame now\r\n');
        } else {
          write('churn $frame filler filler filler filler filler\r\n');
        }
        await tester.pump(const Duration(milliseconds: 16));

        final offset = controller.paintedViewportOffset;
        final expected = _expectedWashViewRows(controller, visibleRows, offset);
        final painted = renderBox().debugWashViewRows.toSet();

        // LOCKSTEP every churn frame — the painter resolves EXACTLY the current
        // anchor rows: never a stale baked range, never a wash the anchors don't
        // back. (Vacuously true on frames where discovery hasn't fired yet — the
        // no-drift check below is what has teeth then.)
        expect(
          painted,
          equals(expected),
          reason: 'churn frame $frame: painted wash rows $painted != '
              'live-resolved $expected (offset=$offset)',
        );
        // NO ACCUMULATION / NO DRIFT: any wash that IS on screen sits on its
        // token's real glyphs — a stale wash left over an overwritten row is the
        // #1069 bug and would trip here.
        expect(_driftedWashes(controller, 62, offset), isEmpty,
            reason: 'churn frame $frame: a visible wash sat off its token');
      }

      // The stream PAUSES: one final URL, then let the debounce fire. Debounced
      // discovery now anchors the settled URL even without a max-wait ceiling.
      write('final line visit https://example.com/live/final now\r\n');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        controller.highlights
            .any((r) => r.capsule && '${r.payload}'.contains('live/final')),
        isTrue,
        reason: 'once streaming settles the last URL must anchor on its token — '
            'the wash appears at rest (debounced discovery)',
      );
      final offset = controller.paintedViewportOffset;
      expect(renderBox().debugWashViewRows.toSet(),
          equals(_expectedWashViewRows(controller, visibleRows, offset)),
          reason: 'the settled wash resolves exactly the live anchor rows');
      expect(_driftedWashes(controller, 62, offset), isEmpty,
          reason: 'the settled wash sits on its token');

      // Drain the trailing scroll-settle / detection-debounce timers the final
      // append re-armed so the framework's "no pending timers" invariant holds.
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 40 && controller.isScrolling; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 200));
      debugPrint('WASH1067 churn OK: lockstep + no-drift every frame; settled '
          'URL anchored on-glyph once the stream paused');
    },
  );
}
