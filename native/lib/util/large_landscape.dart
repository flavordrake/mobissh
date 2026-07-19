// #1086: the "large landscape" layout signal — a wide, landscape surface
// (tablet, Android desktop mode / freeform, DeX, connected display) that
// warrants the desktop-style layout (menus on top, keybar hidden by default)
// instead of the phone-portrait chrome.
//
// Gated on BOTH a wide width AND landscape orientation, so a phone merely rotated
// to landscape (short) does not trip it, but a genuinely large window does. The
// threshold is Material's "expanded" window-class width (~840dp). Pure function
// of the viewport size so it is trivially unit-testable; call it with
// `MediaQuery.sizeOf(context)` at the use site.

import 'dart:ui' show Size;

/// Width (in logical px) at/above which — when also landscape — the layout is
/// treated as large. ~840dp is Material 3's expanded window-class breakpoint.
const double kLargeLandscapeMinWidth = 840.0;

/// True when [size] is a large landscape surface: landscape orientation
/// (width > height) AND width ≥ [kLargeLandscapeMinWidth].
bool isLargeLandscape(Size size) {
  final landscape = size.width > size.height;
  return landscape && size.width >= kLargeLandscapeMinWidth;
}
