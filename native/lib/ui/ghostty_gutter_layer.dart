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
// resolved against the PAINTED offset #955), and hides mid-scroll like the old
// decorator did (the controller's `isScrolling` gate).
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
/// Thin so it never eats terminal real estate; the strip is a translucent
/// overlay, not a reserved column (the PTY grid width is unchanged).
const double kGutterStripWidth = 16.0;

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
/// (#805) and HIDES while [TerminalController.isScrolling] (#812) — the marks
/// reappear, in lockstep with the painted rows, once the scroll settles. Reads
/// `controller.anchors`, resolves each row via `controller.anchorGutterRow`, and
/// places a mark at `padding + row * cellHeight` on the right edge. Sits ABOVE
/// the gesture router so a tap on a mark is consumed by the mark (everywhere
/// else is transparent and falls through).
class GhosttyGutterLayer extends StatelessWidget {
  const GhosttyGutterLayer({
    super.key,
    required this.controller,
    required this.registry,
    required this.color,
    required this.cellHeight,
    this.padding = 4.0,
    this.stripWidth = kGutterStripWidth,
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.decorationListenable,
      builder: (context, _) {
        // #812: don't draw mid-scroll — the marks reappear on settle. (Tap
        // routing via the gesture router's matchAt is unaffected.)
        if (controller.isScrolling) return const SizedBox.shrink();
        if (cellHeight <= 0) return const SizedBox.shrink();
        final byRow = groupAnchorsByGutterRow(
          controller.anchors,
          gutterRowOf: controller.anchorGutterRow,
          hasPresentation: (id) => registry.forPattern(id) != null,
        );
        if (byRow.isEmpty) return const SizedBox.shrink();
        return Stack(
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
                width: stripWidth,
                top: padding + entry.key * cellHeight,
                height: cellHeight,
                child: _GutterMark(
                  key: Key('gutter-mark-${entry.key}'),
                  anchors: entry.value,
                  registry: registry,
                  color: color,
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
class _GutterMark extends StatelessWidget {
  const _GutterMark({
    super.key,
    required this.anchors,
    required this.registry,
    required this.color,
  });

  final List<StructuredAnchor> anchors;
  final GutterPatternRegistry registry;
  final Color color;

  void _onTap(BuildContext context, Offset markGlobal) {
    if (anchors.length == 1) {
      final presentation = registry.forPattern(anchors.first.patternId);
      if (presentation == null) return;
      presentation.showActions(context, anchors.first, markGlobal);
      return;
    }
    showGutterPatternList(
      context,
      anchors: anchors,
      registry: registry,
      color: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final multi = anchors.length > 1;
    final single = registry.forPattern(anchors.first.patternId);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _onTap(context, details.globalPosition),
      child: Center(
        child: multi
            ? Container(
                width: 14,
                height: 14,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1.2),
                ),
                child: Text(
                  '${anchors.length}',
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : Icon(single?.icon ?? Icons.adjust, size: 14, color: color),
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
