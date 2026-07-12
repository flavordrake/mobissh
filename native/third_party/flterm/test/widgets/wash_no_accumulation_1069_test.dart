@Tags(['ffi'])
library;

// #1069 (owner P0) — the ACCUMULATION test the whole rollback exists for.
//
// An in-place-repainting TUI (Claude Code redrawing a status area with cursor
// addressing + `\x1b[2K`) OVERWRITES cells at FIXED absolute rows every frame,
// some frames carrying a detectable pattern and some not. The #1044 retained-
// match scan cache assumed scrollback rows are append-stable and RETAINED old
// matches whose cells had since been overwritten — so their washes ACCUMULATED
// over text that no longer held the payload (the owner's screenshot: washes over
// `all-memories`, `usage-ledger`, `manual mode on`).
//
// The rollback restores the pre-#1044 model: DISCOVERY of a new match is
// debounced, but EVICTION of a match whose anchored cells were repainted with
// different/erased text is SYNCHRONOUS (`_pruneStaleDetections`, #873). This
// test pins the no-accumulation guarantee directly:
//   * the set of live anchor payloads == the set of payloads CURRENTLY on the
//     screen at every settle (never a superset — no stale/accumulated anchor);
//   * when a pattern's row is overwritten with non-pattern text its anchor
//     DISAPPEARS within a single frame (immediate eviction, not debounced);
//   * no visible wash ever sits over cells that do not hold its payload.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HighlightStyle? _washResolver(StructuredMatch m) {
  if (m.patternId != 'url') return null;
  return const HighlightStyle(background: Color(0x8800FF00), capsule: true);
}

// The 1-based rows of the "status area" the TUI repaints in place. Well inside a
// 36-row grid so appends never scroll them and cursor addressing is stable.
const _statusRows = [5, 8, 11];

void main() {
  testWidgets(
    'in-place repaint of fixed rows never accumulates washes — live anchor set '
    'equals the patterns CURRENTLY on screen; an overwritten pattern evicts '
    'within one frame (#1069)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      )
        ..registerTextPattern(TextPattern.url())
        ..detectionHighlightStyleOf = _washResolver;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 620,
              child: TerminalView(controller: controller, autofocus: false),
            ),
          ),
        ),
      );
      await tester.pump();

      void write(String s) =>
          controller.write(Uint8List.fromList(utf8.encode(s)));

      // Overwrite 1-based [row] IN PLACE: absolute cursor address + erase whole
      // line + new text. No newline → the viewport never scrolls, the row keeps
      // its absolute buffer coordinate (the append-stable frame the #1044 cache
      // wrongly trusted), and the cells are rewritten under any live anchor.
      void writeRow(int row, String text) => write('\x1b[$row;1H\x1b[2K$text');

      // The URL payload a row currently shows, or null for a non-pattern row.
      String? urlForRow(int row, int iter, bool hasUrl) =>
          hasUrl ? 'https://example.com/r$row/i$iter' : null;

      // The set of payloads currently painted on the status rows.
      Set<String> onScreenPayloads(Map<int, String?> rows) =>
          {for (final p in rows.values) ?p};

      // Live anchor payloads restricted to the url pattern.
      Set<String> liveUrlAnchors() => {
            for (final a in controller.anchors)
              if (a.patternId == 'url') '${a.payload}',
          };

      // Every capsule wash cell-run currently sitting over cells that do NOT
      // hold its payload — must always be empty (no stale wash over stale text).
      List<String> driftedWashes() {
        final offset = controller.paintedViewportOffset;
        final visible = controller.scrollbar.visible;
        final out = <String>[];
        for (final r in controller.highlights) {
          if (!r.capsule) continue;
          final payload = '${r.payload}';
          for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
            final viewRow = absRow - offset;
            if (viewRow < 0 || viewRow >= visible) continue;
            final startCol = absRow == r.topRow ? r.topCol : 0;
            final endCol = absRow == r.bottomRow ? r.bottomCol : 62;
            final rowText = controller.visibleRowsText(viewRow, viewRow);
            final s = startCol.clamp(0, rowText.length);
            final e = endCol.clamp(0, rowText.length);
            final slice = (e > s ? rowText.substring(s, e) : '').trim();
            final onGlyph = slice.isNotEmpty &&
                (payload.contains(slice) || slice.contains(payload));
            if (!onGlyph) out.add('abs=$absRow "$slice" != $payload');
          }
        }
        return out;
      }

      Future<void> settle() async {
        // Discovery debounce (~120ms) + a paint, then drain any settle timer.
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
      }

      // ---- Phase 1: a pattern appears, anchors after the debounce ----
      final p1 = urlForRow(5, 0, true)!;
      writeRow(5, p1);
      await settle();
      expect(liveUrlAnchors(), equals({p1}),
          reason: 'the freshly painted URL anchored');
      expect(driftedWashes(), isEmpty);

      // ---- Phase 2: overwrite that SAME row with non-pattern text ----
      // Eviction is SYNCHRONOUS (#873) — a single frame, NOT a settle.
      writeRow(5, 'all-memories usage-ledger manual mode on');
      await tester.pump(const Duration(milliseconds: 16));
      expect(liveUrlAnchors(), isEmpty,
          reason: 'the overwritten URL must evict within ONE frame — a retained '
              'match here is the #1069 accumulation (wash over non-pattern text)');
      expect(driftedWashes(), isEmpty,
          reason: 'no wash may linger over the overwritten cells');

      // ---- Phase 3: heavy in-place churn, deterministic URL/non-URL per row ----
      // A fixed pseudo-pattern flips each status row between a UNIQUE URL and
      // plain text every iteration. Unique payloads make any stale anchor from a
      // PRIOR iteration show up immediately as an extra live anchor.
      var maxAnchorsSeen = 0;
      for (var iter = 1; iter <= 30; iter++) {
        final rows = <int, String?>{};
        for (var r = 0; r < _statusRows.length; r++) {
          final row = _statusRows[r];
          // Deterministic churn: each row toggles on a different period so the
          // count of on-screen URLs varies (0..3) across iterations.
          final hasUrl = ((iter + r) % (r + 2)) == 0;
          final payload = urlForRow(row, iter, hasUrl);
          rows[row] = payload;
          writeRow(row, payload ?? 'status $row idle no-link here row=$row');
        }
        await settle();

        final expected = onScreenPayloads(rows);
        final live = liveUrlAnchors();
        expect(live, equals(expected),
            reason: 'iter $iter: live anchors $live != on-screen patterns '
                '$expected — a mismatch is accumulation (superset) or a missed '
                'eviction');
        expect(driftedWashes(), isEmpty,
            reason: 'iter $iter: a wash sits over non-pattern text');
        maxAnchorsSeen =
            live.length > maxAnchorsSeen ? live.length : maxAnchorsSeen;
      }

      // Non-vacuous: the churn really did surface multiple concurrent washes at
      // some point (so the count-equality assertion had teeth).
      expect(maxAnchorsSeen, greaterThan(1),
          reason: 'the churn never surfaced 2+ concurrent washes — the '
              'no-accumulation assertion was vacuous');

      // ---- Phase 4: blank every status row — nothing must remain ----
      for (final row in _statusRows) {
        writeRow(row, 'plain text row $row nothing to detect at all');
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect(liveUrlAnchors(), isEmpty,
          reason: 'after every pattern row is overwritten no anchor may survive');

      await settle();
      expect(liveUrlAnchors(), isEmpty,
          reason: 'and none may re-appear after the debounce either');
      expect(driftedWashes(), isEmpty);
      debugPrint('WASH1069 no-accumulation OK: maxConcurrent=$maxAnchorsSeen, '
          'anchors always == on-screen patterns, eviction within one frame');
    },
  );
}
