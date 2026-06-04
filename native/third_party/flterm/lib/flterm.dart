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

export 'src/foundation/callbacks.dart' show OnResize;
export 'src/foundation/color_palette.dart' show ColorPalette;
export 'src/foundation/dynamic_color.dart' show DynamicColor;
export 'src/foundation/input_types.dart' show KeyboardState, MouseAutoHide;
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
export 'src/widgets/terminal_controller.dart' show TerminalController;
export 'src/widgets/terminal_scope.dart' show TerminalScope;
export 'src/widgets/terminal_scroll_controller.dart'
    show TerminalScrollController, TerminalScrollPosition;
export 'src/widgets/terminal_view.dart' show TerminalView;
