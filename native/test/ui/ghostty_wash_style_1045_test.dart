// #1074 — the app half of the LIVE wash LAYER (decouple the wash from the paint
// cycle). This file was the #1045 render-box resolver's test
// (ghostty_wash_style_1045_test.dart); #1074 relocated the wash to
// [GhosttyWashLayer] painted UNDER a transparent terminal, so it now covers the
// widget-layer seams:
//
//  - ghosttyPatternPaintsWash routing (unchanged contract: command gutter-only).
//  - ghosttyWashCapsuleColor: the pure gate composes pattern routing + the
//    #990/#995 visibility suppression + the #990 verified shade over the #1031
//    resolver; an EMPTY store reproduces the shipped #1000 wash derivation.
//  - GhosttyAnchorWash: reuses highlightCapsuleRRect geometry, drops degenerate
//    rects, rounds caps ONLY on the true first/last on-screen rect.
//  - ghosttyResolveWashes: rebuilt LIVE from the current anchor set — tracking,
//    eviction within one call, and NON-accumulation are inherent.
//  - GhosttyWashLayer widget: rebuilds on the decoration listenable AND the
//    verification listenable; paints only while wash-painting anchors exist.
//
// No FFI: a fake controller supplies scripted anchors + rects. The real
// composite (wash shows through default-bg, explicit-bg occludes) is a fork FFI
// test (transparent_background + wash_underlay) and the on-emulator acceptance.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/ui/detection_style_resolver.dart';
import 'package:mobissh/ui/ghostty_terminal_decorators.dart';

const _accent = Color(0xFF5B9BD5);

Color _resolverWash(
  DetectionStyleResolver resolver,
  String patternId, {
  required bool verified,
}) => resolver.resolveStyle(patternId, verified: verified).washColor;

StructuredAnchor _anchor(
  String patternId,
  String payload, {
  int row = 2,
  int startCol = 4,
  int len = 6,
}) => StructuredAnchor(
  patternId: patternId,
  payload: payload,
  ranges: [
    HighlightRange(
      startRow: row,
      startCol: startCol,
      endRow: row,
      endCol: startCol + len,
      payload: payload,
    ),
  ],
);

/// A soft-wrapped anchor: one range per [rows] entry, in order.
StructuredAnchor _wrapped(String patternId, String payload, List<int> rows) =>
    StructuredAnchor(
      patternId: patternId,
      payload: payload,
      ranges: [
        for (final r in rows)
          HighlightRange(
              startRow: r, startCol: 0, endRow: r, endCol: 5, payload: payload),
      ],
    );

/// Fake controller exposing scripted [anchors] + an [anchorRects] driven by a
/// swappable range→rects map, so a test can move / evict an anchor's on-screen
/// geometry between builds. The only surface [GhosttyWashLayer] reads.
class _FakeController extends ChangeNotifier implements TerminalController {
  List<StructuredAnchor> _anchors = const [];
  Map<HighlightRange, List<Rect>> _rects = const {};

  void setAnchors(
    List<StructuredAnchor> anchors,
    Map<HighlightRange, List<Rect>> rects,
  ) {
    _anchors = anchors;
    _rects = rects;
    notifyListeners();
  }

  @override
  List<StructuredAnchor> get anchors => _anchors;

  @override
  Listenable get decorationListenable => this;

  @override
  List<Rect> anchorRects(HighlightRange range) => _rects[range] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A test-owned verification signal (#990) standing in for SessionPathVerifier.
class _TestSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

void main() {
  group('ghosttyPatternPaintsWash (routing, unchanged)', () {
    test('url / osc8 / path / relpath / custom.* paint the wash', () {
      expect(ghosttyPatternPaintsWash(kGhosttyUrlPatternId), isTrue);
      expect(ghosttyPatternPaintsWash(kGhosttyOsc8PatternId), isTrue);
      expect(ghosttyPatternPaintsWash(kGhosttyPathPatternId), isTrue);
      expect(ghosttyPatternPaintsWash(kGhosttyRelPathPatternId), isTrue);
      expect(ghosttyPatternPaintsWash('custom.my-tickets'), isTrue);
    });

    test('the command BLOCK pattern stays gutter-only (#998 C)', () {
      expect(ghosttyPatternPaintsWash(kGhosttyCommandPatternId), isFalse);
    });

    test('unknown ids paint nothing', () {
      expect(ghosttyPatternPaintsWash('selection'), isFalse);
    });
  });

  group('ghosttyWashCapsuleColor (#1074 pure gate)', () {
    const resolver = DetectionStyleResolver(
      styles: DetectionStyles.empty,
      accent: _accent,
      backgroundBrightness: Brightness.dark,
    );
    Color washColorOf(String patternId, {required bool verified}) =>
        _resolverWash(resolver, patternId, verified: verified);

    test('a visible URL anchor resolves the shipped #1000 wash colour', () {
      final color = ghosttyWashCapsuleColor(
        patternId: kGhosttyUrlPatternId,
        visible: true,
        verified: false,
        washColorOf: washColorOf,
      );
      // ZERO CHANGE: an empty store composes to the shipped #1000 derivation.
      expect(
        color,
        ghosttyBubbleWashColor(
          _accent,
          verified: false,
          backgroundBrightness: Brightness.dark,
        ),
      );
    });

    test('a VERIFIED path anchor gets the bolder #990 shade', () {
      final color = ghosttyWashCapsuleColor(
        patternId: kGhosttyPathPatternId,
        visible: true,
        verified: true,
        washColorOf: washColorOf,
      );
      expect(
        color,
        ghosttyBubbleWashColor(
          _accent,
          verified: true,
          backgroundBrightness: Brightness.dark,
        ),
      );
    });

    test('a SUPPRESSED anchor paints NOTHING (#990/#995 one seam)', () {
      expect(
        ghosttyWashCapsuleColor(
          patternId: kGhosttyPathPatternId,
          visible: false,
          verified: false,
          washColorOf: washColorOf,
        ),
        isNull,
      );
    });

    test('the command block resolves to null regardless of visibility', () {
      expect(
        ghosttyWashCapsuleColor(
          patternId: kGhosttyCommandPatternId,
          visible: true,
          verified: false,
          washColorOf: washColorOf,
        ),
        isNull,
      );
    });

    test('a stored override flows through (Detection Lab live-apply)', () {
      const overrideWash = Color(0x4D33AA55);
      final color = ghosttyWashCapsuleColor(
        patternId: kGhosttyUrlPatternId,
        visible: true,
        verified: false,
        washColorOf: (id, {required bool verified}) =>
            id == kGhosttyUrlPatternId
                ? overrideWash
                : washColorOf(id, verified: verified),
      );
      expect(color, overrideWash);
    });
  });

  group('GhosttyAnchorWash (capsule geometry)', () {
    const color = Color(0x5500FF00);

    test('single rect → one FULLY-rounded capsule (highlightCapsuleRRect)', () {
      const rect = Rect.fromLTWH(10, 20, 40, 16);
      final wash = GhosttyAnchorWash.fromRects(const [rect], color)!;
      expect(wash.capsules(), [
        highlightCapsuleRRect(rect, roundLeft: true, roundRight: true),
      ]);
    });

    test('multi-row wrap rounds caps ONLY on first/last row', () {
      const r0 = Rect.fromLTWH(10, 20, 40, 16);
      const r1 = Rect.fromLTWH(0, 36, 30, 16);
      final wash = GhosttyAnchorWash.fromRects(const [r0, r1], color)!;
      expect(wash.capsules(), [
        highlightCapsuleRRect(r0, roundLeft: true, roundRight: false),
        highlightCapsuleRRect(r1, roundLeft: false, roundRight: true),
      ]);
    });

    test('degenerate rects are dropped; all-degenerate → null', () {
      const good = Rect.fromLTWH(1, 2, 10, 16);
      final wash = GhosttyAnchorWash.fromRects(
        const [Rect.fromLTWH(0, 0, 0, 16), good, Rect.zero],
        color,
      )!;
      expect(wash.rects, const [good]);
      expect(
        GhosttyAnchorWash.fromRects(const [Rect.zero], color),
        isNull,
      );
    });
  });

  group('ghosttyResolveWashes (#1074 LIVE from the anchor set)', () {
    const wash = Color(0x5511AA33);
    Color? paintUrl(StructuredAnchor a) =>
        a.patternId == kGhosttyUrlPatternId ? wash : null;

    test('one wash per wash-painting on-screen anchor; command skipped', () {
      final url = _anchor(kGhosttyUrlPatternId, 'https://a');
      final cmd = _anchor(kGhosttyCommandPatternId, 'ls -la');
      final rects = {
        url.ranges.first: const [Rect.fromLTWH(4, 32, 60, 16)],
        cmd.ranges.first: const [Rect.fromLTWH(0, 48, 60, 16)],
      };
      final washes = ghosttyResolveWashes(
        [url, cmd],
        rectsOf: (r) => rects[r] ?? const [],
        washColorFor: paintUrl,
      );
      // Only the URL paints (command gutter-only → null colour → dropped).
      expect(washes, hasLength(1));
      expect(washes.single.color, wash);
      expect(washes.single.rects, const [Rect.fromLTWH(4, 32, 60, 16)]);
    });

    test('TRACKS: the same anchor moves with its rects between builds', () {
      final url = _anchor(kGhosttyUrlPatternId, 'https://a');
      List<GhosttyAnchorWash> resolve(Rect at) => ghosttyResolveWashes(
            [url],
            rectsOf: (_) => [at],
            washColorFor: paintUrl,
          );
      expect(resolve(const Rect.fromLTWH(4, 32, 60, 16)).single.rects,
          const [Rect.fromLTWH(4, 32, 60, 16)]);
      // Painted offset changed → same anchor, new rect. No stale band.
      expect(resolve(const Rect.fromLTWH(4, 16, 60, 16)).single.rects,
          const [Rect.fromLTWH(4, 16, 60, 16)]);
    });

    test('EVICTS within one call: dropped anchor / off-screen rects vanish', () {
      final a = _anchor(kGhosttyUrlPatternId, 'https://a');
      final b = _anchor(kGhosttyUrlPatternId, 'https://b', row: 4);
      final rects = {
        a.ranges.first: const [Rect.fromLTWH(0, 32, 40, 16)],
        b.ranges.first: const [Rect.fromLTWH(0, 64, 40, 16)],
      };
      List<Rect> rectsOf(HighlightRange r) => rects[r] ?? const [];
      expect(
        ghosttyResolveWashes([a, b], rectsOf: rectsOf, washColorFor: paintUrl),
        hasLength(2),
      );
      // b removed from the anchor set → gone on the very next call (one frame).
      expect(
        ghosttyResolveWashes([a], rectsOf: rectsOf, washColorFor: paintUrl),
        hasLength(1),
      );
      // a still present but its rects scrolled off-screen (empty) → dropped.
      expect(
        ghosttyResolveWashes([a],
            rectsOf: (_) => const [], washColorFor: paintUrl),
        isEmpty,
      );
    });

    test('does NOT accumulate: repeated calls yield the current set only', () {
      final url = _anchor(kGhosttyUrlPatternId, 'https://a');
      List<Rect> rectsOf(HighlightRange r) => const [Rect.fromLTWH(0, 0, 40, 16)];
      final first =
          ghosttyResolveWashes([url], rectsOf: rectsOf, washColorFor: paintUrl);
      final second =
          ghosttyResolveWashes([url], rectsOf: rectsOf, washColorFor: paintUrl);
      // Same input → identical set, never doubled (no baked/cached state).
      expect(first, second);
      expect(second, hasLength(1));
    });

    test('a wrapped anchor collects all on-screen rows into one wash', () {
      final url = _wrapped(kGhosttyUrlPatternId, 'https://wrapped', [2, 3]);
      final rects = {
        url.ranges[0]: const [Rect.fromLTWH(20, 32, 40, 16)],
        url.ranges[1]: const [Rect.fromLTWH(0, 48, 30, 16)],
      };
      final washes = ghosttyResolveWashes(
        [url],
        rectsOf: (r) => rects[r] ?? const [],
        washColorFor: paintUrl,
      );
      expect(washes, hasLength(1));
      expect(washes.single.rects, hasLength(2));
      // First row rounds left only, last row rounds right only (one object).
      expect(washes.single.capsules(), [
        highlightCapsuleRRect(const Rect.fromLTWH(20, 32, 40, 16),
            roundLeft: true, roundRight: false),
        highlightCapsuleRRect(const Rect.fromLTWH(0, 48, 30, 16),
            roundLeft: false, roundRight: true),
      ]);
    });
  });

  group('GhosttyWashLayer widget', () {
    Widget host(_FakeController controller, {Listenable? verify}) => Directionality(
          textDirection: TextDirection.ltr,
          child: GhosttyWashLayer(
            controller: controller,
            washColorFor: (a) =>
                a.patternId == kGhosttyUrlPatternId ? const Color(0x5500FF00) : null,
            repaintListenable: verify,
          ),
        );

    testWidgets('paints only while wash-painting anchors exist', (tester) async {
      final controller = _FakeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));
      // No anchors → nothing painted.
      expect(find.byKey(const Key('ghostty-wash-paint')), findsNothing);

      final url = _anchor(kGhosttyUrlPatternId, 'https://a');
      controller.setAnchors(
        [url],
        {url.ranges.first: const [Rect.fromLTWH(0, 0, 40, 16)]},
      );
      await tester.pump();
      expect(find.byKey(const Key('ghostty-wash-paint')), findsOneWidget);

      // Anchor evicted → the layer collapses (no stale band).
      controller.setAnchors(const [], const {});
      await tester.pump();
      expect(find.byKey(const Key('ghostty-wash-paint')), findsNothing);
    });

    testWidgets('rebuilds on the VERIFICATION listenable (no anchor change)',
        (tester) async {
      final controller = _FakeController();
      final verify = _TestSignal();
      addTearDown(controller.dispose);
      addTearDown(verify.dispose);

      // A path anchor whose colour depends on a mutable "verified" flag, flipped
      // by the verification signal — proves the merged listenable rebuilds the
      // layer with no change to the anchor SET.
      var verified = false;
      final path = _anchor(kGhosttyPathPatternId, '/etc/hosts', startCol: 0);
      final rects = {path.ranges.first: const [Rect.fromLTWH(0, 0, 40, 16)]};

      Color washColorFor(StructuredAnchor a) =>
          verified ? const Color(0xFFAA0000) : const Color(0x5500FF00);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GhosttyWashLayer(
            controller: controller,
            washColorFor: washColorFor,
            repaintListenable: verify,
          ),
        ),
      );
      controller.setAnchors([path], rects);
      await tester.pump();
      CustomPaint paint() => tester.widget<CustomPaint>(
            find.byKey(const Key('ghostty-wash-paint')),
          );
      final before = paint().painter;

      // Verification lands: no anchor change, only the signal fires.
      verified = true;
      verify.fire();
      await tester.pump();
      final after = paint().painter;
      // The painter was rebuilt (a new instance with the verified colour), so a
      // stat result recolours the wash in place.
      expect(identical(before, after), isFalse);
    });
  });
}
