/// Flutter terminal renderer powered by libghostty.
///
/// ```dart
/// import 'package:flterm/flterm.dart';
/// ```
library;

export 'package:libghostty/libghostty.dart'
    show
        CursorShape,
        DeviceAttributesResponse,
        Formatter,
        FormatterExtra,
        FormatterFormat,
        Key,
        Mods,
        MouseTracking,
        Scrollbar,
        TerminalMode,
        TerminalScreen,
        UnderlineStyle,
        initializeForWeb;

// #988: the pure anchor→viewport-rect resolver is part of the public geometry
// seam — the app's bubble decorator (and its headless tests) resolve per-row
// rects with the SAME math `anchorRects` uses.
export 'src/foundation/anchor_geometry.dart' show AnchorGeometry;
export 'src/foundation/callbacks.dart' show OnResize;
export 'src/foundation/cell_metrics.dart' show CellMetrics;
export 'src/foundation/color_palette.dart' show ColorPalette;
// #1044: detection hot-path counters — the replay perf suite and bug-report
// telemetry read these off `TerminalController.detectionScanStats`.
export 'src/foundation/detection_scan_stats.dart' show DetectionScanStats;
export 'src/foundation/dynamic_color.dart' show DynamicColor;
// #1045: the capsule wash geometry is shared with the app's Detection Lab
// preview so the preview renders EXACTLY the fork's behind-glyph look.
export 'src/foundation/highlight_range.dart'
    show
        HighlightRange,
        HighlightTheme,
        highlightCapsuleRRect,
        kHighlightCapsuleBottomOutset,
        kHighlightCapsulePadX,
        kHighlightCapsuleTopInset;
export 'src/foundation/input_types.dart' show KeyboardState, MouseAutoHide;
export 'src/foundation/structured_text.dart'
    show
        CellReader,
        HighlightStyle,
        StructuredAnchor,
        StructuredMatch,
        StructuredTextScanner,
        TextPattern,
        TextTier,
        kDefaultCommandLexicon;
export 'src/foundation/terminal_config.dart'
    show ScrollToBottom, TerminalConfig;
export 'src/foundation/terminal_gesture_settings.dart'
    show
        GestureModifier,
        LineSelectMode,
        SelectionGesture,
        TerminalGestureSettings;
export 'src/foundation/terminal_selection.dart'
    show TerminalSelection, TerminalSelectionMode;
export 'src/foundation/terminal_theme.dart'
    show
        CursorTheme,
        HyperlinkStyle,
        HyperlinkTheme,
        SelectionTheme,
        TerminalTheme;
// #918: expose the render box so the host widget can force a full repaint
// (`forceRepaint()`) after dispatching user input — the input-driven half of the
// force-repaint robustness layer.
export 'src/rendering/terminal_renderer.dart'
    show TerminalRenderBox, TerminalRenderer;
export 'src/widgets/terminal_controller.dart' show TerminalController;
export 'src/widgets/terminal_scope.dart' show TerminalScope;
export 'src/widgets/terminal_scroll_controller.dart'
    show TerminalScrollController, TerminalScrollPosition;
export 'src/widgets/terminal_view.dart' show TerminalView;
