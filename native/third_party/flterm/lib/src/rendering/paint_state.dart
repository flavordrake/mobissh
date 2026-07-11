import 'dart:typed_data';
import 'dart:ui';

import 'package:libghostty/libghostty.dart' show Cursor, TerminalColors;

import '../foundation.dart'
    show CellMetrics, HighlightRange, TerminalSelection, TerminalTheme;
import 'atlas/atlas.dart';

/// Mutable state shared between [TerminalRenderBox] and all painters.
///
/// Written by the render box during state sync (start of paint). Read by
/// painters during the paint phase. Each painter holds a final reference
/// and never mutates this object.
///
/// Contains grid dimensions, device pixel ratio, resolved terminal
/// colors, selection state, cursor state, IME preedit state, and faint text
/// opacity.
class TerminalPaintState {
  TerminalTheme theme;
  CellMetrics metrics;

  var rows = 0;
  var cols = 0;
  var blinkVisible = true;

  /// Scale between Flutter's logical-pixel canvas and the physical
  /// pixels libghostty uses for size reports and Kitty graphics.
  var devicePixelRatio = 1.0;

  late int terminalForegroundArgb;
  late int terminalBackgroundArgb;
  final terminalPaletteArgb = Uint32List(256);

  /// Alpha byte (0-255) applied to faint text foregrounds.
  int faintAlpha;

  TerminalSelection? selection;

  /// Additive structured-text highlight ranges (URLs, paths, regex matches).
  ///
  /// Absolute buffer rows; the highlight painter maps them to viewport rows
  /// using [viewportOffset] each frame. Empty when nothing is highlighted.
  List<HighlightRange> highlights = const [];

  var viewportOffset = 0;

  /// #1062: while the painted viewport offset is actively CHANGING (a user
  /// scroll / fling, or a streaming-output auto-scroll), the detection WASH
  /// [highlights] is HIDDEN. The render box sets this each paint from the
  /// controller's `isScrolling`. It exists because during a scroll the
  /// rescan/relocate that keeps a wash's ABSOLUTE rows aligned to its token is
  /// DEFERRED (#1044 scan-gating), so a mid-scroll wash can sit over the cells
  /// where its token USED to be (the owner's "pinned wash"). Rather than chase
  /// the offset per frame (float/pin, burned twice), the wash follows the #988
  /// bubble stance: hidden while in flight, re-derived + re-shown on settle at
  /// the correct offset. The [HighlightPainter] early-returns when this is set.
  var washSuppressed = false;

  var cursor = const Cursor();
  var cursorWide = false;
  var cursorFocused = true;
  var cursorColorArgb = 0xFFFFFFFF;
  AtlasEntry? cursorAtlasEntry;
  final cursorGlyphPaint = Paint();

  /// Whether preedit text currently replaces cells at the cursor row.
  ///
  /// Cursor painting reads this to avoid drawing the normal terminal cursor
  /// over the active composing range.
  var preeditActive = false;

  TerminalPaintState(this.theme, this.metrics)
    : faintAlpha = (theme.faintOpacity * 255).ceil() {
    terminalForegroundArgb = theme.foreground.toARGB32();
    terminalBackgroundArgb = theme.background.toARGB32();
    _updateThemePalette();
  }

  void updateTheme(TerminalTheme newTheme) {
    theme = newTheme;
    faintAlpha = (newTheme.faintOpacity * 255).ceil();
    _updateThemePalette();
  }

  /// Updates resolved terminal colors.
  ///
  /// Returns true when any color changed so cached paint data containing
  /// packed ARGB values can be rebuilt.
  bool updateTerminalColors(TerminalColors colors) {
    var changed = false;
    final foreground = colors.foreground.toArgb32;
    final background = colors.background.toArgb32;
    if (terminalForegroundArgb != foreground) {
      terminalForegroundArgb = foreground;
      changed = true;
    }
    if (terminalBackgroundArgb != background) {
      terminalBackgroundArgb = background;
      changed = true;
    }
    final palette = colors.palette;
    for (var i = 0; i < terminalPaletteArgb.length; i++) {
      final color = palette[i].toArgb32;
      if (terminalPaletteArgb[i] == color) continue;
      terminalPaletteArgb[i] = color;
      changed = true;
    }
    return changed;
  }

  void _updateThemePalette() {
    final palette = theme.palette;
    for (var i = 0; i < terminalPaletteArgb.length; i++) {
      terminalPaletteArgb[i] = palette[i].toARGB32();
    }
  }
}
