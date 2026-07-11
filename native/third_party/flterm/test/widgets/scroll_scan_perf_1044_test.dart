// #1044 — scroll must not pay for detection: a PURE viewport fling performs
// ZERO scan work (no regex passes, no cell re-reads), with discovery deferred
// to the quiesce (settle) pass.
//
// The pre-fix hot path re-validated EVERY live anchor synchronously on EVERY
// scroll tick (`_onScrollChanged` → `_pruneStaleDetections` → per-match
// `_scanWindow`: an FFI cell re-read plus a full pattern pass), and the
// debounced `_rescanDetections` re-read a ~440-row window regardless of what
// changed. With the pattern-set multipliers (relpath #1036, custom patterns
// #1035, the command scorer #998) that put O(anchors × patterns) regex passes
// + FFI reads on every fling frame — the owner-reported scroll lag.
//
// This test drives a REAL TerminalView fling via an external scroll
// controller and counts regex passes through counting-wrapper RegExps
// (deliberately NOT the #1044 stats seam, so the same file measures pre-fix
// code for the before/after numbers in the PR). Invariants pinned:
//   1. a pure fling performs ZERO regex passes (scan work is content-driven,
//      not viewport-driven);
//   2. the anchors survive the fling (nothing was evicted by scrolling);
//   3. after the quiesce pass, newly-revealed scrollback rows ARE scanned —
//      a URL far above the initially-scanned window is discovered once the
//      viewport settles over it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A RegExp wrapper that counts scanner passes (allMatches / firstMatch /
/// hasMatch) before delegating, so scan work is observable without any seam
/// in the production code (this same file measures PRE-fix code for the
/// before/after numbers, where the #1044 stats getter does not exist).
// Implementing RegExp is the whole point of the counting seam — TextPattern
// consumes a RegExp, so only an implements-wrapper can observe its passes.
// ignore: deprecated_implement
class CountingRegExp implements RegExp {
  CountingRegExp(String source) : _inner = RegExp(source);

  final RegExp _inner;
  int passes = 0;

  @override
  Iterable<RegExpMatch> allMatches(String input, [int start = 0]) {
    passes++;
    return _inner.allMatches(input, start);
  }

  @override
  RegExpMatch? firstMatch(String input) {
    passes++;
    return _inner.firstMatch(input);
  }

  @override
  bool hasMatch(String input) {
    passes++;
    return _inner.hasMatch(input);
  }

  @override
  String? stringMatch(String input) => _inner.stringMatch(input);

  @override
  Match? matchAsPrefix(String string, [int start = 0]) =>
      _inner.matchAsPrefix(string, start);

  @override
  String get pattern => _inner.pattern;

  @override
  bool get isCaseSensitive => _inner.isCaseSensitive;

  @override
  bool get isMultiLine => _inner.isMultiLine;

  @override
  bool get isUnicode => _inner.isUnicode;

  @override
  bool get isDotAll => _inner.isDotAll;
}

void main() {
  const topUrl = 'https://top-of-history.example.com/discover-on-quiesce';

  testWidgets(
    'a pure viewport fling performs ZERO detection regex passes; anchors '
    'survive; quiesce discovers newly-revealed scrollback (#1044)',
    (tester) async {
      final controller = TerminalController(
        config: const TerminalConfig(cols: 62, rows: 36),
      );
      addTearDown(controller.dispose);

      // The realistic multiplied pattern set: url + path + relpath-shaped +
      // 2 custom patterns, all with counting regexes. (Shapes mirror the
      // built-ins closely enough to measure scheduling; exact regex parity is
      // not the point — pass COUNTS are.)
      final counters = <CountingRegExp>[
        CountingRegExp(r'(?:https?://|www\.)[^\s<>"' "'" r'`]+'),
        CountingRegExp(r'(?<![\w.\-~@+:/])/(?:[\w.\-~@+]+/?)+'),
        CountingRegExp(r'(?<![\w.\-~@+:/])[\w.\-@+]+(?:/[\w.\-~@+]+)+/?'),
        CountingRegExp(r'ISSUE-\d+'),
        CountingRegExp(r'\b[0-9a-f]{7,40}\b'),
      ];
      final ids = ['url', 'path', 'relpath', 'custom.issue', 'custom.sha'];
      for (var i = 0; i < counters.length; i++) {
        controller.registerTextPattern(
          TextPattern(id: ids[i], regex: counters[i]),
        );
      }

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

      void write(String s) {
        controller.write(Uint8List.fromList(utf8.encode(s)));
      }

      // A seq-style flood with anchors sprinkled through it: the top URL
      // (outside the initial bounded scan window once 800 lines land), then
      // filler with a URL/path every 40 lines so anchors are on screen at
      // every fling position.
      write('$topUrl\r\n');
      for (var i = 0; i < 800; i++) {
        if (i % 40 == 0) {
          write('line ${i.toString().padLeft(5, '0')} '
              'https://example.com/page/$i and /etc/hosts too\r\n');
        } else {
          write('line ${i.toString().padLeft(5, '0')} '
              'filler filler filler filler\r\n');
        }
      }
      // Settle output, the detection debounce (~120ms), and the scroll-settle
      // timer (~140ms).
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        controller.anchors.any(
          (a) => '${a.payload}'.contains('example.com/page/'),
        ),
        isTrue,
        reason: 'precondition: anchors are live before the fling',
      );
      final anchorsBefore = controller.anchors.length;

      // ---- the measured fling: 60 frames of pure viewport movement ----
      for (final c in counters) {
        c.passes = 0;
      }
      final position = scrollController.position;
      final startPixels = position.pixels;
      final wall = Stopwatch()..start();
      for (var frame = 1; frame <= 60; frame++) {
        position.jumpTo(startPixels - frame * 40.0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      wall.stop();
      final flingPasses =
          counters.fold<int>(0, (sum, c) => sum + c.passes);

      // Numbers for the PR (before/after runs of this same file).
      debugPrint('PERF#1044 fling: regexPasses=$flingPasses '
          'wallMs=${wall.elapsedMilliseconds} anchorsLive=$anchorsBefore');

      expect(
        flingPasses,
        0,
        reason: 'a pure viewport fling must perform ZERO detection regex '
            'passes — scan work is content-driven and quiesce-deferred, '
            'never viewport-driven (#1044)',
      );

      // ---- quiesce: the settle pass reconciles, anchors survive ----
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(
        controller.anchors.any(
          (a) => '${a.payload}'.contains('example.com/page/'),
        ),
        isTrue,
        reason: 'anchors must survive a pure viewport fling + quiesce',
      );

      // ---- discovery on quiesce: scroll to the very top; the settle pass
      // scans the newly-revealed rows and the top URL anchors. ----
      controller.scrollToTop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(
        controller.anchors.any((a) => a.payload == topUrl),
        isTrue,
        reason: 'after quiesce over newly-revealed scrollback the top URL '
            'must be discovered (#1044 settle reconcile)',
      );
    },
  );
}
