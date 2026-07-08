// ghostty_gutter_layer.dart — GUTTER-surfaced structured-text detection (#955).
//
// THE PIVOT (why this replaces the inline highlight): the old inline decorations
// (the URL bubble / path underline in `ghostty_terminal_decorators.dart`) had to
// hug the matched glyph cells to sub-pixel precision EVERY frame. During a
// scroll the painted glyphs and the resolved rects could disagree by a fraction
// of a row, so the decoration "danced" off its text — the still-open #930 and
// the #803/#812/#863/#864 saga. A GUTTER indicator needs only a ROW + a fixed
// edge X, so that whole drift class is GONE: there is no text under the mark to
// drift away from. It tracks scroll by row index alone (`anchorGutterRow`, now
// resolved against the PAINTED offset #955). #993: it TRACKS mid-scroll too —
// the decoration listenable fires post-frame on every painted-offset change, so
// each notify re-resolves every mark's viewport row in lockstep with the
// painted glyphs (the old `isScrolling` hide was the bubble's sub-pixel-drift
// contract; a row-indexed chip has nothing to drift, and hiding left the chips
// visibly pinned on scroll paths where `isScrolling` never engages).
//
// The layer reads the controller's live `anchors`, resolves each to a VIEWPORT
// row via `anchorGutterRow` (dropping off-screen/null), GROUPS anchors by row,
// and renders ONE small monochrome mark per matched row at the RIGHT edge (a
// thin translucent strip overlay — NOT a reserved column, so the PTY column
// count is untouched). A row with several matches (e.g. a URL AND a path —
// possible since both detectors run in slices 1+2) shows a count and, on tap,
// a list sheet of every match on the line. A single-match row taps straight
// through to the existing action overlay (`showUrlActions`/`showPathActions`).
//
// Dispatch is a `patternId → GutterPatternPresentation` map ({icon, single-tap
// action, list-item actions}) so adding a future pattern (slice 4 custom regex)
// is a trivial registry entry — no new paint code, no fork change.
//
// Per memory feedback_monochrome_icons_no_emoji the mark is a Material glyph in
// the theme highlight colour (currentColor), never an emoji.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';

import '../services/clipboard.dart';
import 'path_action_overlay.dart';
import 'top_toast.dart';
import 'url_action_overlay.dart';
import 'ghostty_terminal_decorators.dart';

/// Width (logical px) of the right-edge gutter strip the marks sit in (#955).
/// Still a translucent overlay, not a reserved column (the PTY grid width is
/// unchanged). #989 widened it from 16 to match the line-select strip
/// (`kGutterSelectStripWidth`) so the bigger chip fits inside it.
const double kGutterStripWidth = 28.0;

/// Sizing + colour derivation for the gutter detection mark chip (#989).
///
/// The mark is a FILLED opaque chip behind a bigger glyph so it reads as a
/// physical, tappable button against terminal text in both themes — not a
/// faint 14px glyph. Kept as a value type so #990's VERIFIED-path variant is
/// one more static const (a bolder shade via [chipColor]) with zero paint-code
/// rework.
@immutable
class GutterMarkStyle {
  const GutterMarkStyle({
    required this.chipSize,
    required this.glyphSize,
    required this.minTapExtent,
    this.ringWidth = 0.0,
  });

  /// The standard mark style — the plain "detected" shade.
  static const GutterMarkStyle normal = GutterMarkStyle(
    chipSize: 24.0,
    glyphSize: 16.0,
    minTapExtent: 40.0,
  );

  /// The BOLD variant (#990): the VERIFIED-path shade. Same geometry and tap
  /// semantics as [normal] plus a contrast RING around the chip (stroked in
  /// [onChipColor], so it stays monochrome + theme-compliant and reads at
  /// phone density where a subtle fill change would not).
  static const GutterMarkStyle bold = GutterMarkStyle(
    chipSize: 24.0,
    glyphSize: 16.0,
    minTapExtent: 40.0,
    ringWidth: 2.5,
  );

  /// Diameter of the filled chip behind the glyph.
  final double chipSize;

  /// Glyph (icon) size inside the chip; the count badge scales off it.
  final double glyphSize;

  /// Minimum effective touch target (Material's comfortable ~40dp minimum).
  /// The mark's HIT box is expanded to this even though the painted chip is
  /// smaller — the extra area is invisible and centred on the row.
  final double minTapExtent;

  /// Width of the contrast ring around the chip — 0 for the plain detected
  /// shade, >0 for the bold VERIFIED shade (#990).
  final double ringWidth;

  /// The chip fill: the theme accent forced OPAQUE. The session selection
  /// colour is often translucent (e.g. `0x33` alpha) — a see-through chip has
  /// no contrast over terminal text.
  Color chipColor(Color accent) => accent.withValues(alpha: 1.0);

  /// Contrasting monochrome glyph colour for [chipColor] (luminance-picked, so
  /// the glyph pops on the chip in both light and dark session themes).
  Color onChipColor(Color accent) =>
      ThemeData.estimateBrightnessForColor(chipColor(accent)) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

/// One tap action shown for a match in the multi-match list sheet (#955).
@immutable
class GutterItemAction {
  const GutterItemAction({
    required this.keyLabel,
    required this.icon,
    required this.label,
    required this.onInvoke,
  });

  /// Short stable id used in the widget key (`gutter-item-<i>-<keyLabel>`), so a
  /// test can find a specific action button. Lowercase, no spaces (e.g. `open`).
  final String keyLabel;

  /// Monochrome Material glyph for the action (currentColor).
  final IconData icon;

  /// Human label (also the tooltip).
  final String label;

  /// Perform the action. Receives the tile's [BuildContext] (still mounted at
  /// invoke time) so it can resolve the root overlay for a toast.
  final Future<void> Function(BuildContext context) onInvoke;
}

/// Presentation + dispatch for ONE detected pattern in the gutter (#955).
///
/// The registry maps a [StructuredAnchor.patternId] to this. [icon] is the mark
/// glyph (and the list-item leading glyph); [showActions] is the single-match
/// tap (mirrors the long-press action overlay, minus the rect geometry — the
/// gutter has only a row + edge); [itemActions] builds the per-match buttons for
/// the multi-match list sheet.
@immutable
class GutterPatternPresentation {
  const GutterPatternPresentation({
    required this.patternId,
    required this.icon,
    required this.typeLabel,
    required this.showActions,
    required this.itemActions,
  });

  final String patternId;

  /// Monochrome Material glyph for this pattern (e.g. a link / folder icon).
  final IconData icon;

  /// Short type label for the list sheet subtitle (e.g. `Link`, `Path`).
  final String typeLabel;

  /// Single-match tap: open this pattern's action overlay, anchored near the
  /// tapped gutter mark ([markGlobal]). No rect geometry — the gutter is row +
  /// edge only.
  final void Function(
    BuildContext context,
    StructuredAnchor anchor,
    Offset markGlobal,
  ) showActions;

  /// The action buttons for this pattern's row in the multi-match list sheet.
  final List<GutterItemAction> Function(String payload) itemActions;
}

/// Maps a pattern id to its [GutterPatternPresentation] (#955).
class GutterPatternRegistry {
  GutterPatternRegistry(Iterable<GutterPatternPresentation> presentations)
    : _byPattern = {for (final p in presentations) p.patternId: p};

  /// The standard registry: URLs (regex + OSC-8) and absolute file paths.
  ///
  /// [openPath] navigates the SFTP explorer to a tapped path (the view passes
  /// its `_openPath`); injectable so a widget test asserts the dispatch without
  /// pushing a real route. URL opening + clipboard honour the existing
  /// `url_action_overlay` / `clipboard` test seams.
  factory GutterPatternRegistry.standard({
    required Future<bool> Function(String path) openPath,
  }) {
    GutterItemAction copyAction(String payload) => GutterItemAction(
      keyLabel: 'copy',
      icon: Icons.content_copy,
      label: 'Copy',
      onInvoke: (context) => _copyWithToast(context, payload),
    );

    final url = GutterPatternPresentation(
      patternId: kGhosttyUrlPatternId,
      icon: Icons.link,
      typeLabel: 'Link',
      showActions: (context, anchor, markGlobal) => showUrlActions(
        context,
        '${anchor.payload}',
        highlightRects: const [],
        anchor: markGlobal,
      ),
      itemActions: (payload) => [
        copyAction(payload),
        GutterItemAction(
          keyLabel: 'open',
          icon: Icons.open_in_new,
          label: 'Open',
          onInvoke: (context) async {
            final overlay = Overlay.maybeOf(context, rootOverlay: true);
            final ok = await openDetectedUrl(payload);
            if (!ok && overlay != null) {
              showTopToastInOverlay(overlay, 'Could not open: $payload');
            }
          },
        ),
      ],
    );

    final path = GutterPatternPresentation(
      patternId: kGhosttyPathPatternId,
      icon: Icons.folder_open,
      typeLabel: 'Path',
      showActions: (context, anchor, markGlobal) => showPathActions(
        context,
        '${anchor.payload}',
        highlightRects: const [],
        anchor: markGlobal,
        onOpen: openPath,
      ),
      itemActions: (payload) => [
        GutterItemAction(
          keyLabel: 'open',
          icon: Icons.folder_open,
          label: 'Open',
          onInvoke: (context) async {
            final overlay = Overlay.maybeOf(context, rootOverlay: true);
            final ok = await openPath(payload);
            if (!ok && overlay != null) {
              showTopToastInOverlay(overlay, 'Could not open: $payload');
            }
          },
        ),
        copyAction(payload),
      ],
    );

    return GutterPatternRegistry([
      url,
      // OSC-8 hyperlinks render the SAME affordance as a regex URL.
      GutterPatternPresentation(
        patternId: kGhosttyOsc8PatternId,
        icon: url.icon,
        typeLabel: url.typeLabel,
        showActions: url.showActions,
        itemActions: url.itemActions,
      ),
      path,
    ]);
  }

  final Map<String, GutterPatternPresentation> _byPattern;

  /// The presentation for [patternId], or null when none is registered.
  GutterPatternPresentation? forPattern(String patternId) =>
      _byPattern[patternId];

  /// The registered pattern ids (for tests / introspection).
  Iterable<String> get patternIds => _byPattern.keys;
}

/// Copy [text] to the clipboard and toast via the ROOT overlay (#955).
///
/// The overlay is captured BEFORE the async clipboard write so the toast still
/// lands after the list sheet has popped (the root overlay outlives the sheet).
Future<void> _copyWithToast(BuildContext context, String text) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final ok = await copyToClipboard(text);
  if (ok && overlay != null) showTopToastInOverlay(overlay, 'Copied: $text');
}

/// Group detected [anchors] by the VIEWPORT row their gutter mark belongs on
/// (#955). PURE (no widget) → unit-testable.
///
/// [gutterRowOf] resolves a range to its top visible viewport row (or null when
/// off-screen) — in production `controller.anchorGutterRow`. [hasPresentation]
/// drops anchors whose pattern has no registered mark. A multi-row (soft-wrapped)
/// anchor collapses to ONE row: its FIRST on-screen range. An anchor with every
/// range off-screen is excluded.
Map<int, List<StructuredAnchor>> groupAnchorsByGutterRow(
  Iterable<StructuredAnchor> anchors, {
  required int? Function(HighlightRange range) gutterRowOf,
  required bool Function(String patternId) hasPresentation,
}) {
  final byRow = <int, List<StructuredAnchor>>{};
  for (final anchor in anchors) {
    if (!hasPresentation(anchor.patternId)) continue;
    int? row;
    for (final range in anchor.ranges) {
      final r = gutterRowOf(range);
      if (r != null) {
        row = r;
        break;
      }
    }
    if (row == null) continue;
    (byRow[row] ??= <StructuredAnchor>[]).add(anchor);
  }
  return byRow;
}

/// The right-edge GUTTER overlay: one tappable monochrome mark per matched
/// viewport row (#955). Replaces the inline `GhosttyTerminalDecoratorLayer`.
///
/// Listens to the controller's NARROW [TerminalController.decorationListenable]
/// (#805), which fires post-frame on every painted-offset change while anchors
/// exist — so during a scroll the marks TRACK their line (#993): every notify
/// re-resolves each anchor's viewport row via `controller.anchorGutterRow`
/// (painted-offset, frame-synced) and repositions the mark at
/// `padding + row * cellHeight` on the right edge, in lockstep with the painted
/// glyphs. No mid-scroll hide (that is the bubble's #812 sub-pixel contract);
/// taps ARE ignored while [TerminalController.isScrolling], since a chip can
/// change rows between tapDown and tapUp. Sits ABOVE the gesture router so a
/// tap on a mark is consumed by the mark (everywhere else is transparent and
/// falls through).
class GhosttyGutterLayer extends StatelessWidget {
  const GhosttyGutterLayer({
    super.key,
    required this.controller,
    required this.registry,
    required this.color,
    required this.cellHeight,
    this.padding = 4.0,
    this.stripWidth = kGutterStripWidth,
    this.style = GutterMarkStyle.normal,
    this.isVerified,
    this.isVisible,
    this.verifiedStyle = GutterMarkStyle.bold,
    this.verificationListenable,
  });

  /// The SAME controller handed to the flterm `TerminalView`.
  final TerminalController controller;

  /// Pattern-id → presentation map.
  final GutterPatternRegistry registry;

  /// Theme highlight colour the marks paint in (the session selection colour).
  final Color color;

  /// The REAL flterm cell height (from `ghosttyMeasureCellSize`), to place a
  /// mark at its row's pixel Y. The same value the painter/gesture map use.
  final double cellHeight;

  /// The flterm `TerminalView` padding the grid is offset by (kept in sync with
  /// `kGhosttyTerminalPadding`; defaulted so this file needn't import the view).
  final double padding;

  /// Width of the right-edge strip the marks sit in.
  final double stripWidth;

  /// Chip sizing + colour derivation for the marks (#989).
  final GutterMarkStyle style;

  /// #990: OPAQUE verification predicate. True → the anchor's row renders in
  /// [verifiedStyle] (the bold shade). Null → every mark stays [style]. The
  /// layer deliberately doesn't know WHY an anchor is verified (today:
  /// exists-on-host via the session's SFTP stat) so the predicate's meaning
  /// can change without paint rework.
  final bool Function(StructuredAnchor anchor)? isVerified;

  /// #990 visibility gate: OPAQUE suppression predicate — false means the
  /// anchor gets NO gutter mark at all (a low-confidence single-segment match
  /// awaiting verification, or confirmed missing). A suppressed anchor also
  /// drops out of a multi-match row's count. Null → everything shows.
  final bool Function(StructuredAnchor anchor)? isVisible;

  /// The bold shade for verified anchors (#990).
  final GutterMarkStyle verifiedStyle;

  /// #990: fires when a verification result lands (no anchor change involved)
  /// so the marks repaint. Merged with the controller's decoration listenable.
  final Listenable? verificationListenable;

  @override
  Widget build(BuildContext context) {
    final verification = verificationListenable;
    return ListenableBuilder(
      listenable: verification == null
          ? controller.decorationListenable
          : Listenable.merge([controller.decorationListenable, verification]),
      builder: (context, _) {
        // #993: no isScrolling hide here — each painted-offset notify lands
        // post-frame and `anchorGutterRow` resolves against that same painted
        // offset, so re-grouping below moves every chip to its line's new
        // viewport row in lockstep with the painted glyphs. (The notify only
        // fires when the offset actually changed, so a settled terminal never
        // rebuilds this.) Taps are gated on isScrolling inside _GutterMark.
        if (cellHeight <= 0) return const SizedBox.shrink();
        final byRow = groupAnchorsByGutterRow(
          // #990 visibility gate: suppressed anchors never reach the grouping,
          // so a suppressed match neither marks its row nor inflates a count.
          isVisible == null
              ? controller.anchors
              : [
                  for (final a in controller.anchors)
                    if (isVisible!(a)) a,
                ],
          gutterRowOf: controller.anchorGutterRow,
          hasPresentation: (id) => registry.forPattern(id) != null,
        );
        if (byRow.isEmpty) return const SizedBox.shrink();
        // #989: the HIT box is at least minTapExtent square (invisible slack
        // centred on the row); the painted chip stays inside the strip.
        final boxWidth = stripWidth > style.minTapExtent
            ? stripWidth
            : style.minTapExtent;
        final boxHeight = cellHeight > style.minTapExtent
            ? cellHeight
            : style.minTapExtent;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Translucent right-edge strip (visual hint only, never absorbs
            // taps — the marks below it are the hit targets).
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: stripWidth,
              child: IgnorePointer(
                child: ColoredBox(color: color.withValues(alpha: 0.06)),
              ),
            ),
            for (final entry in byRow.entries)
              Positioned(
                right: 0,
                width: boxWidth,
                top:
                    padding +
                    entry.key * cellHeight -
                    (boxHeight - cellHeight) / 2,
                height: boxHeight,
                child: _GutterMark(
                  key: Key('gutter-mark-${entry.key}'),
                  controller: controller,
                  anchors: entry.value,
                  registry: registry,
                  color: color,
                  // #990: a row with ANY verified anchor renders the bold
                  // shade (a multi-match row's badge inherits it too).
                  style: (isVerified != null && entry.value.any(isVerified!))
                      ? verifiedStyle
                      : style,
                  stripWidth: stripWidth,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One row's mark: a single-pattern glyph (taps straight to the action overlay)
/// or a count badge for a multi-match row (taps to the list sheet) (#955).
///
/// #989: the glyph sits on a FILLED opaque chip ([GutterMarkStyle]) so it reads
/// as a physical button, and the chip scales down while pressed (cheap
/// [AnimatedScale] — no cost when idle). Tap SEMANTICS are unchanged.
class _GutterMark extends StatefulWidget {
  const _GutterMark({
    super.key,
    required this.controller,
    required this.anchors,
    required this.registry,
    required this.color,
    required this.style,
    required this.stripWidth,
  });

  /// #993: consulted at tap time — while the painted offset is still moving a
  /// chip can change rows between tapDown and tapUp, so taps are ignored.
  final TerminalController controller;

  final List<StructuredAnchor> anchors;
  final GutterPatternRegistry registry;
  final Color color;
  final GutterMarkStyle style;
  final double stripWidth;

  @override
  State<_GutterMark> createState() => _GutterMarkState();
}

class _GutterMarkState extends State<_GutterMark> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _onTap(BuildContext context, Offset markGlobal) {
    // #993: mid-scroll the chip under the finger is not a stable target — the
    // row it marks may have changed since tapDown. Firing here could invoke a
    // DIFFERENT line's action, so ignore the tap (pre-#993 this state was
    // unreachable: the whole layer hid while scrolling).
    if (widget.controller.isScrolling) return;
    final anchors = widget.anchors;
    if (anchors.length == 1) {
      final presentation = widget.registry.forPattern(anchors.first.patternId);
      if (presentation == null) return;
      presentation.showActions(context, anchors.first, markGlobal);
      return;
    }
    showGutterPatternList(
      context,
      anchors: anchors,
      registry: widget.registry,
      color: widget.color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final multi = widget.anchors.length > 1;
    final single = widget.registry.forPattern(widget.anchors.first.patternId);
    final chipFill = style.chipColor(widget.color);
    final onChip = style.onChipColor(widget.color);
    // Centre the chip inside the visible strip (the hit box is wider).
    final inset = (widget.stripWidth - style.chipSize) / 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (details) {
        _setPressed(false);
        _onTap(context, details.globalPosition);
      },
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: EdgeInsets.only(right: inset > 0 ? inset : 0),
          child: AnimatedScale(
            scale: _pressed ? 0.85 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
              width: style.chipSize,
              height: style.chipSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: chipFill,
                // #990: the VERIFIED shade — a contrast ring (bold), absent on
                // the plain detected chip.
                border: style.ringWidth > 0
                    ? Border.all(color: onChip, width: style.ringWidth)
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: multi
                  ? Text(
                      '${widget.anchors.length}',
                      style: TextStyle(
                        color: onChip,
                        fontSize: style.glyphSize * 0.75,
                        height: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : Icon(
                      single?.icon ?? Icons.adjust,
                      size: style.glyphSize,
                      color: onChip,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Show the multi-match list sheet for a gutter row (#955): every match on the
/// line, each with its payload, a pattern glyph, and its action buttons.
Future<void> showGutterPatternList(
  BuildContext context, {
  required List<StructuredAnchor> anchors,
  required GutterPatternRegistry registry,
  required Color color,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final tiles = <Widget>[];
      for (var i = 0; i < anchors.length; i++) {
        final presentation = registry.forPattern(anchors[i].patternId);
        if (presentation == null) continue;
        tiles.add(
          _GutterPatternListTile(
            index: i,
            anchor: anchors[i],
            presentation: presentation,
          ),
        );
      }
      return SafeArea(
        child: ListView(
          key: const Key('gutter-pattern-list'),
          shrinkWrap: true,
          children: tiles,
        ),
      );
    },
  );
}

/// One match row in the gutter list sheet (#955).
class _GutterPatternListTile extends StatelessWidget {
  const _GutterPatternListTile({
    required this.index,
    required this.anchor,
    required this.presentation,
  });

  final int index;
  final StructuredAnchor anchor;
  final GutterPatternPresentation presentation;

  @override
  Widget build(BuildContext context) {
    final payload = '${anchor.payload}';
    final actions = presentation.itemActions(payload);
    return ListTile(
      key: Key('gutter-item-$index'),
      leading: Icon(presentation.icon),
      title: Text(payload, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(presentation.typeLabel),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions)
            IconButton(
              key: Key('gutter-item-$index-${action.keyLabel}'),
              icon: Icon(action.icon),
              tooltip: action.label,
              onPressed: () {
                // Fire the action with the still-mounted tile context (it grabs
                // the root overlay for any toast), then dismiss the sheet.
                action.onInvoke(context);
                Navigator.of(context).maybePop();
              },
            ),
        ],
      ),
    );
  }
}
