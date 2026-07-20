// #1086: the "large landscape" layout signal — a wide, landscape surface on an
// OBVIOUS TABLET (or Android desktop mode / freeform / DeX / connected display /
// desktop-web window) that warrants the desktop-style layout (menus on top,
// compact top-left session indicator, keybar hidden by default) instead of the
// phone-portrait chrome.
//
// "Obvious tablet" (owner 2026-07-20: "adopt tablet ux principles when on an
// obvious tablet") means big in BOTH dimensions, so it needs THREE things:
//   1. landscape (width > height), and
//   2. an EXPANDED width (≥ 840dp, Material 3's expanded window class), and
//   3. a tablet-class SHORTEST side (≥ 600dp, Material's tablet threshold).
//
// Requiring both a wide long edge AND a tall short edge is what separates a
// tablet from a phone: a phone in landscape is wide (~915dp) but its short edge
// is only ~360–430dp, so condition (3) rejects it — the earlier width-only rule
// wrongly gave it the desktop chrome. It also keeps the 800×600 Flutter test
// canvas (narrow, 800 < 840) on the phone layout, so terminal-chrome tests don't
// silently flip. Pure function of the viewport size so it is trivially
// unit-testable; call it with `MediaQuery.sizeOf(context)` at the use site.

import 'dart:ui' show Size;

/// Long-edge width (logical px) at/above which a landscape surface is "expanded"
/// (Material 3's expanded window class). A phone in landscape can clear this, so
/// it is necessary but NOT sufficient — see [kTabletMinShortestSide].
const double kExpandedMinWidth = 840.0;

/// Shortest-side width (logical px) at/above which a surface is tablet-class
/// rather than a phone. 600dp is Material's tablet threshold — a phone's short
/// edge stays well below it even in landscape, so this is what excludes a phone.
const double kTabletMinShortestSide = 600.0;

/// True when [size] is a large landscape surface on an obvious tablet: landscape
/// (width > height) AND width ≥ [kExpandedMinWidth] AND shortest side ≥
/// [kTabletMinShortestSide].
bool isLargeLandscape(Size size) {
  final landscape = size.width > size.height;
  final shortestSide = size.width < size.height ? size.width : size.height;
  return landscape &&
      size.width >= kExpandedMinWidth &&
      shortestSide >= kTabletMinShortestSide;
}
