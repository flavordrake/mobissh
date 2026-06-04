import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart' as vt;
import 'package:libghostty/libghostty.dart' hide KeyEvent;
import 'package:meta/meta.dart';

import '../foundation.dart';
import '../rendering/kitty_png_decoder.dart';
import 'terminal_controller.dart';
import 'terminal_input_client.dart';
import 'terminal_view_binding.dart';

@internal
class TerminalControllerImpl extends TerminalController
    implements TerminalViewBinding {
  static const _cr = 0x0d;
  static const _del = 0x7f;
  static const _formFeed = 0x0c;
  static const _space = 0x20;
  static const _macFunctionKeyStart = 0xF700;
  static const _macFunctionKeyEnd = 0xF8FF;

  static final _crBytes = Uint8List.fromList([_cr]);
  static final _formFeedBytes = Uint8List.fromList([_formFeed]);
  static final _clearScrollback = utf8.encode('\x1b[3J');
  static final _appCursorDown = Uint8List.fromList([0x1b, 0x4f, 0x42]);
  static final _appCursorUp = Uint8List.fromList([0x1b, 0x4f, 0x41]);
  static final _cursorDown = Uint8List.fromList([0x1b, 0x5b, 0x42]);
  static final _cursorUp = Uint8List.fromList([0x1b, 0x5b, 0x41]);

  @override
  final Terminal terminal;
  final _renderState = RenderState();
  final _keyEncoder = KeyEncoder();
  final _mouseEncoder = MouseEncoder();
  final vt.KeyEvent _keyEvent;
  final MouseEvent _mouseEvent;
  final TerminalInputClient _textInput;

  TerminalConfig _config;
  TerminalScreen _activeScreen = .primary;
  MouseTracking _mouseTracking = .none;
  KeyboardState _keyboardState = .hidden;
  Mods _virtualMods = const .none();
  var _preeditText = '';
  var _cursorKeyApplication = false;
  Brightness _brightness = .dark;
  var _cursorBlinking = true;
  var _wasFocused = false;

  CellMetrics _lastMetrics = const .new(
    cellWidth: 0,
    cellHeight: 0,
    baseline: 0,
  );
  var _lastDevicePixelRatio = 1.0;

  FocusNode? _focusNode;
  TerminalSelection? _selection;
  ScrollController? _scrollController;

  TerminalControllerImpl({TerminalConfig config = const TerminalConfig()})
    : _config = config,
      _keyEvent = vt.KeyEvent(),
      _mouseEvent = MouseEvent(),
      _textInput = TerminalInputClient(),
      terminal = Terminal(
        cols: config.cols,
        rows: config.rows,
        maxScrollback: config.scrollbackLimit,
      ),
      super.base() {
    installDefaultKittyPngDecoder();
    _applyTerminalOptions();
    _textInput
      ..onTextCommitted = _handleTextCommitted
      ..onDelete = _handleDelete
      ..onPreeditChanged = _handlePreeditChanged
      ..onNewline = _handleNewline;
    _wireTerminalCallbacks();
    _applyModes();
    terminal.addListener(_onTerminalChanged);
  }

  @override
  TerminalScreen get activeScreen => _activeScreen;

  @override
  set brightness(Brightness value) {
    _textInput.keyboardAppearance = value;
    _brightness = value;
  }

  @override
  TerminalConfig get config => _config;

  @override
  set config(TerminalConfig value) {
    if (_config == value) return;
    _config = value;
    _applyTerminalOptions();
    _applyModes();
    _wireTerminalCallbacks();
    notifyListeners();
  }

  @override
  bool get cursorBlinks {
    if (!_cursorBlinking || !hasFocus) return false;
    if (_activeScreen == .alternate) return true;
    final sc = _scrollController;
    if (sc == null || !sc.hasClients) return true;
    final pos = sc.position;
    if (!pos.hasContentDimensions) return true;
    return pos.pixels >= pos.maxScrollExtent - 1.0;
  }

  @override
  bool get hasFocus => _focusNode?.hasFocus ?? false;

  @override
  KeyboardState get keyboardState => _keyboardState;

  @override
  MouseTracking get mouseTracking => _mouseTracking;

  @override
  String get preeditText => _preeditText;

  @override
  String get pwd => terminal.pwd;

  @override
  int get scrollbackRows => terminal.scrollbackRows;

  @override
  Scrollbar get scrollbar => terminal.scrollbar;

  @override
  TerminalSelection? get selection => _selection;

  @override
  set selection(TerminalSelection? value) {
    if (_selection == value) return;
    _selection = value;
    notifyListeners();
  }

  @override
  String get title => terminal.title;

  @override
  int get totalRows => terminal.totalRows;

  @override
  Mods get virtualMods => _virtualMods;

  bool get _hasActiveComposition =>
      _textInput.hasActiveComposition || _preeditText.isNotEmpty;

  bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      .linux || .macOS || .windows => true,
      .android || .fuchsia || .iOS => false,
    };
  }

  bool get _shouldForwardCompositionKeyToTextInput {
    return _hasActiveComposition && _textInput.isAttached && _isDesktopPlatform;
  }

  @override
  void attach(FocusNode focusNode, ScrollController scrollController) {
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode = focusNode;
    _wasFocused = focusNode.hasFocus;
    _focusNode!.addListener(_onFocusChanged);
    _textInput.keyboardAppearance = _brightness;
    if (_wasFocused && _keyboardState != .disabled) {
      if (_keyboardState == .showing) {
        _textInput.show();
      } else {
        _textInput.ensureAttached(keyboardAppearance: _brightness);
      }
    }
    _scrollController = scrollController;
  }

  @override
  void clear() {
    if (_activeScreen == .alternate) return;
    clearSelection();
    terminal.write(_clearScrollback);
    _emitOutput(_formFeedBytes);
  }

  @override
  void clearSelection() => selection = null;

  @override
  void clearVirtualMods() {
    if (_virtualMods.isEmpty) return;
    _virtualMods = const .none();
    notifyListeners();
  }

  @override
  Formatter createFormatter({
    required FormatterFormat format,
    bool unwrap = false,
    bool trim = false,
    FormatterExtra extra = const FormatterExtra(),
  }) {
    return Formatter(
      terminal: terminal,
      format: format,
      unwrap: unwrap,
      trim: trim,
      extra: extra,
    );
  }

  @override
  void detach() {
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode = null;
    _wasFocused = false;
    _keyboardState = .hidden;
    _preeditText = '';
    _scrollController = null;
    _textInput.detach();
  }

  @override
  void disableKeyboard() => _updateKeyboardState(.disabled);

  @override
  void dispose() {
    terminal.removeListener(_onTerminalChanged);
    detach();
    _keyEvent.dispose();
    _mouseEvent.dispose();
    _keyEncoder.dispose();
    _mouseEncoder.dispose();
    _renderState.dispose();
    terminal.dispose();
    super.dispose();
  }

  @override
  KeyEventResult handleKeyEvent(KeyEvent event) {
    if (!_hasActiveComposition &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        HardwareKeyboard.instance.isShiftPressed &&
        _selection != null) {
      if (_extendSelection(event.logicalKey)) return .handled;
    }

    final key = keyFromPhysical(event.physicalKey);
    final KeyAction? action = switch (event) {
      KeyDownEvent() => .press,
      KeyUpEvent() => .release,
      KeyRepeatEvent() => .repeat,
      _ => null,
    };

    if (action == null) return .ignored;

    if (_shouldForwardCompositionKeyToTextInput) {
      return .skipRemainingHandlers;
    }

    final unshiftedCodepoint = unshiftedCodepointForKey(key);
    final mods = _currentMods();
    final character = _encoderCharacter(event.character);
    final consumedMods = _consumedModsFor(
      character,
      unshiftedCodepoint: unshiftedCodepoint,
      mods: mods,
    );

    _keyEvent
      ..key = key
      ..mods = mods
      ..action = action
      ..utf8 = character
      ..consumedMods = consumedMods
      ..unshiftedCodepoint = unshiftedCodepoint
      ..composing = _hasActiveComposition;

    _keyEncoder.sync(terminal);
    final result = _keyEncoder.encode(_keyEvent);
    if (result.isEmpty) return _hasActiveComposition ? .handled : .ignored;

    if (_shouldRouteKeyThroughTextInput(
      action: action,
      character: character,
      encoded: result,
      mods: mods,
    )) {
      _onTextInput();
      return .skipRemainingHandlers;
    }

    clearVirtualMods();
    final forwardToPlatformIme = _consumeCommittedCompositionEditKey(
      key,
      action,
      mods,
    );
    _emitOutput(utf8.encode(result));
    _onTextInput();

    return forwardToPlatformIme ? .skipRemainingHandlers : .handled;
  }

  @override
  void handleMouseEvent(TerminalMouseEvent event) {
    _mouseEvent
      ..action = event.action
      ..button = event.button
      ..mods = _currentMods()
      ..setPosition(
        x: event.pixelX * _lastDevicePixelRatio,
        y: event.pixelY * _lastDevicePixelRatio,
      );
    _mouseEncoder.sync(terminal);
    final result = _mouseEncoder.encode(_mouseEvent);
    if (result.isEmpty) return;
    _emitOutput(utf8.encode(result));
  }

  @override
  void handleResize({
    required int cols,
    required int rows,
    required CellMetrics metrics,
    required EdgeInsets padding,
    required double devicePixelRatio,
  }) {
    _lastMetrics = metrics;
    _lastDevicePixelRatio = devicePixelRatio;
    final cellWidthPx = (metrics.cellWidth * devicePixelRatio).round();
    final cellHeightPx = (metrics.cellHeight * devicePixelRatio).round();
    _mouseEncoder.setSize(
      MouseEncoderSize(
        screenWidth: cols * cellWidthPx,
        screenHeight: rows * cellHeightPx,
        cellWidth: cellWidthPx,
        cellHeight: cellHeightPx,
        paddingLeft: (padding.left * devicePixelRatio).round(),
        paddingRight: (padding.right * devicePixelRatio).round(),
        paddingTop: (padding.top * devicePixelRatio).round(),
        paddingBottom: (padding.bottom * devicePixelRatio).round(),
      ),
    );
    onResize?.call(cols, rows);

    if (terminal.modeGet(const TerminalMode.inBandResize())) {
      final report = SizeReportStyle.mode2048.encode(
        rows: rows,
        columns: cols,
        cellWidth: cellWidthPx,
        cellHeight: cellHeightPx,
      );
      _emitOutput(utf8.encode(report));
    }
  }

  @override
  void handleScroll(int lines) {
    if (_activeScreen != .alternate || lines == 0) return;

    if (_mouseTracking != .none) {
      final button = lines < 0 ? MouseButton.four : MouseButton.five;
      final count = lines.abs();

      if (count > 0) _mouseEncoder.sync(terminal);

      for (var i = 0; i < count; i++) {
        _mouseEvent
          ..action = .press
          ..button = button
          ..mods = _currentMods()
          ..setPosition(x: 0, y: 0);
        final result = _mouseEncoder.encode(_mouseEvent);
        if (result.isNotEmpty) _emitOutput(utf8.encode(result));
      }
      return;
    }

    final up = _cursorKeyApplication ? _appCursorUp : _cursorUp;
    final down = _cursorKeyApplication ? _appCursorDown : _cursorDown;
    final key = lines < 0 ? up : down;
    final count = lines.abs();
    final bytes = Uint8List(key.length * count);
    for (var i = 0; i < count; i++) {
      bytes.setRange(i * key.length, (i + 1) * key.length, key);
    }
    _emitOutput(bytes);
  }

  @override
  void hideKeyboard() => _updateKeyboardState(.hidden);

  @override
  bool modeGet(TerminalMode mode) => terminal.modeGet(mode);

  @override
  void modeSet(TerminalMode mode, {required bool value}) {
    terminal.modeSet(mode, value: value);
  }

  @override
  void paste(String text) {
    if (text.isEmpty) return;
    final bracketed = terminal.modeGet(const .bracketedPaste());
    _emitOutput(pasteEncode(text, bracketed: bracketed));
    _scrollToBottomOnInput();
  }

  @override
  void requestFocus() => _focusNode?.requestFocus();

  @override
  void scrollToBottom() {
    if (_activeScreen == .alternate) return;
    terminal.scrollToBottom();
    final controller = _scrollController;
    if (controller != null && controller.hasClients) {
      final max = controller.position.maxScrollExtent;
      if (max.isFinite) controller.jumpTo(max);
    }
  }

  @override
  void scrollToTop() {
    if (_activeScreen == .alternate) return;
    terminal.scrollToTop();
    final controller = _scrollController;
    if (controller != null && controller.hasClients) controller.jumpTo(0);
  }

  @override
  void selectAll() {
    terminal.scrollToBottom();
    final scrollbackLen = terminal.scrollbackRows;
    _renderState.update(terminal);
    final rows = _renderState.rows;
    final cols = _renderState.cols;

    var lastScreenRow = -1;
    var lastContentCol = 0;
    for (var row = 0; row < rows; row++) {
      var rowLastCol = 0;
      for (var col = 0; col < cols; col++) {
        final ref = GridRef.at(terminal, col: col, row: row);
        final hasContent = ref.graphemes.isNotEmpty;
        ref.dispose();
        if (hasContent) rowLastCol = col + 1;
      }
      if (rowLastCol > 0) {
        lastScreenRow = row;
        lastContentCol = rowLastCol;
      }
    }

    if (lastScreenRow < 0 && scrollbackLen == 0) return;

    final int endRow;
    final int endCol;

    if (lastScreenRow >= 0) {
      endRow = scrollbackLen + lastScreenRow;
      endCol = lastContentCol;
    } else {
      endRow = scrollbackLen - 1;
      endCol = cols;
    }

    selection = TerminalSelection(
      startRow: 0,
      startCol: 0,
      endRow: endRow,
      endCol: endCol,
    );
  }

  @override
  String selectedText({FormatterFormat format = .plain}) {
    final selection = _selection;
    if (selection == null) return '';

    _renderState.update(terminal);
    final cols = _renderState.cols;
    final total = terminal.totalRows;
    if (cols <= 0 || total <= 0) return '';
    final topRow = selection.topRow.clamp(0, total - 1);
    final bottomRow = selection.bottomRow.clamp(0, total - 1);
    if (topRow > bottomRow) return '';

    final block = selection.mode == .block;
    final topCol = selection.topCol.clamp(0, cols - 1);
    final bottomCol = (selection.bottomCol - 1).clamp(0, cols - 1);
    if (block && topCol > bottomCol) return '';

    final formatter = Formatter(
      terminal: terminal,
      format: format,
      unwrap: !block,
      selection: Selection(
        startCol: topCol,
        startRow: topRow,
        endCol: bottomCol,
        endRow: bottomRow,
        rectangle: block,
        pointTag: .screen,
      ),
    );

    try {
      return formatter.format();
    } finally {
      formatter.dispose();
    }
  }

  @override
  void selectLine(int row, LineSelectMode lineSelectMode) {
    final (:startRow, :endRow, :endCol) = terminal.lineBoundaryAt(row);
    final int effectiveEndCol;
    switch (lineSelectMode) {
      case .full:
        _renderState.update(terminal);
        effectiveEndCol = _renderState.cols;
      case .content:
        effectiveEndCol = endCol;
    }
    selection = TerminalSelection(
      startRow: startRow,
      startCol: 0,
      endRow: endRow,
      endCol: effectiveEndCol,
    ).scroll(scrollbar.offset);
  }

  @override
  void selectWord(int row, int col) {
    final adjCol = terminal.snapColToWideBoundary(row, col, inclusive: true);
    final (startCol, endCol) = terminal.wordBoundaryAt(
      row,
      adjCol,
      wordPattern: _config.wordPattern,
    );
    selection = TerminalSelection(
      startRow: row,
      startCol: startCol,
      endRow: row,
      endCol: endCol,
    ).scroll(scrollbar.offset);
  }

  @override
  void sendKey(vt.Key key, {Mods mods = const .none()}) {
    final effectiveMods = mods | _virtualMods;
    final codepoint = unshiftedCodepointForKey(key);
    _keyEvent
      ..key = key
      ..mods = effectiveMods
      ..action = .press
      ..consumedMods = const .none()
      ..unshiftedCodepoint = codepoint
      ..utf8 = codepoint > 0 ? String.fromCharCode(codepoint) : null
      ..composing = false;

    _keyEncoder.sync(terminal);
    final result = _keyEncoder.encode(_keyEvent);
    if (result.isEmpty) return;
    _emitOutput(utf8.encode(result));
    clearVirtualMods();
  }

  @override
  void sendText(String text) {
    if (text.isEmpty) return;
    _emitOutput(utf8.encode(text));
    clearVirtualMods();
  }

  @override
  void showKeyboard() => _updateKeyboardState(.showing);

  @override
  void toggleMod(Mods mod) {
    _virtualMods = _virtualMods ^ mod;
    notifyListeners();
  }

  @override
  void unfocus() => _focusNode?.unfocus();

  @override
  void updateSelection(
    int startRow,
    int startCol,
    int endRow,
    int endCol,
    TerminalSelectionMode mode,
  ) {
    final (sc, ec) = terminal.snapSelectionCols(
      startRow,
      startCol,
      endRow,
      endCol,
    );
    selection = TerminalSelection(
      startRow: startRow,
      startCol: sc,
      endRow: endRow,
      endCol: ec,
      mode: mode,
    ).scroll(scrollbar.offset);
  }

  @override
  void updateTextInputGeometry({
    required Size editableSize,
    required Matrix4 transform,
    required Rect caretRect,
    required Rect composingRect,
  }) {
    _textInput.updateGeometry(
      editableSize: editableSize,
      transform: transform,
      caretRect: caretRect,
      composingRect: composingRect,
    );
  }

  @override
  void write(Uint8List data) => terminal.write(data);

  void _applyModes() {
    for (final entry in _config.modes.entries) {
      terminal.modeSet(entry.key, value: entry.value);
    }
  }

  void _applyTerminalOptions() {
    terminal.kittyImageStorageLimit = _config.kittyImageStorageLimit;
    terminal.setApcBufferLimit(_config.apcBufferLimit);
  }

  bool _consumeCommittedCompositionEditKey(
    vt.Key key,
    KeyAction action,
    Mods mods,
  ) {
    // A plain deletion immediately after a desktop candidate commit belongs
    // to the platform IME first. Modified deletions stay terminal-only so
    // protocol modes and shell shortcuts keep their encoded semantics.
    if (!_isDesktopPlatform) return false;
    if (action != .press && action != .repeat) return false;
    if (key != .backspace && key != .delete) return false;
    if (!mods.isEmpty) return false;
    return _textInput.consumeCommittedCompositionEdit();
  }

  Mods _currentMods() {
    var mods = _virtualMods;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) mods = mods | const .shift();
    if (keyboard.isControlPressed) mods = mods | const .ctrl();
    if (keyboard.isAltPressed) mods = mods | const .alt();
    if (keyboard.isMetaPressed) mods = mods | const .superKey();
    return mods;
  }

  Mods _consumedModsFor(
    String? character, {
    required int unshiftedCodepoint,
    required Mods mods,
  }) {
    // Flutter does not expose consumed modifiers, so this fallback only
    // accounts for Shift producing a different single-codepoint character.
    if (!mods.hasShift || character == null || unshiftedCodepoint == 0) {
      return const .none();
    }

    final codepoints = character.runes.iterator;
    if (!codepoints.moveNext()) return const .none();
    final codepoint = codepoints.current;
    if (codepoints.moveNext()) return const .none();
    if (codepoint == unshiftedCodepoint) return const .none();
    return const .shift();
  }

  bool _emitKeyPress(
    vt.Key key, {
    Mods mods = const .none(),
    bool clearMods = true,
  }) {
    final codepoint = unshiftedCodepointForKey(key);
    _keyEvent
      ..key = key
      ..mods = mods
      ..action = .press
      ..consumedMods = const .none()
      ..unshiftedCodepoint = codepoint
      ..utf8 = codepoint > 0 ? String.fromCharCode(codepoint) : null
      ..composing = false;

    _keyEncoder.sync(terminal);
    final result = _keyEncoder.encode(_keyEvent);
    if (result.isEmpty) return false;

    _emitOutput(utf8.encode(result));
    if (clearMods) clearVirtualMods();
    return true;
  }

  void _emitOutput(Uint8List bytes) => onOutput?.call(bytes);

  bool _extendSelection(LogicalKeyboardKey arrowKey) {
    final (dRow, dCol) = switch (arrowKey) {
      .arrowRight => (0, 1),
      .arrowLeft => (0, -1),
      .arrowUp => (-1, 0),
      .arrowDown => (1, 0),
      _ => (0, 0),
    };
    if (dRow == 0 && dCol == 0) return false;
    _renderState.update(terminal);
    selection = _selection!.moveEnd(
      dRow,
      dCol,
      totalCols: _renderState.cols,
      totalRows: totalRows,
    );
    return true;
  }

  void _handleDelete(int count) {
    if (count <= 0) return;

    var emitted = false;
    for (var i = 0; i < count; i++) {
      emitted =
          _emitKeyPress(.backspace, mods: _currentMods(), clearMods: false) ||
          emitted;
    }
    if (!emitted) return;

    clearVirtualMods();
    _onTextInput();
  }

  void _handleNewline() {
    _emitOutput(_crBytes);
    clearVirtualMods();
    _onTextInput();
  }

  void _handlePreeditChanged(String text) {
    if (_preeditText == text) return;
    _preeditText = text;
    if (text.isNotEmpty) _onTextInput();
    notifyListeners();
  }

  TerminalSizeInfo _handleSizeQuery() {
    _renderState.update(terminal);
    return TerminalSizeInfo(
      rows: _renderState.rows,
      columns: _renderState.cols,
      cellWidth: (_lastMetrics.cellWidth * _lastDevicePixelRatio).round(),
      cellHeight: (_lastMetrics.cellHeight * _lastDevicePixelRatio).round(),
    );
  }

  void _handleTextCommitted(String text) {
    if (_virtualMods.isEmpty) {
      _emitOutput(utf8.encode(text));
      _onTextInput();
      return;
    }

    if (text.length == 1) {
      final key = keyFromCodepoint(text.codeUnitAt(0));
      if (key != null) {
        sendKey(key);
        return;
      }
    }

    _emitOutput(utf8.encode(text));
    clearVirtualMods();
    _onTextInput();
  }

  void _onFocusChanged() {
    final focused = _focusNode?.hasFocus ?? false;
    if (focused == _wasFocused) return;
    _wasFocused = focused;

    if (focused && _keyboardState == .showing) {
      _textInput.show();
    } else if (focused && _keyboardState != .disabled) {
      _textInput.ensureAttached(keyboardAppearance: _brightness);
    } else if (!focused) {
      if (_keyboardState == .showing) _keyboardState = .hidden;
      _textInput.hide();
    }

    if (!focused) clearVirtualMods();

    if (terminal.modeGet(const TerminalMode.focusEvent())) {
      final event = focused ? FocusEvent.gained : FocusEvent.lost;
      _emitOutput(utf8.encode(event.encode()));
    }

    notifyListeners();
  }

  void _onTerminalChanged() {
    var changed = false;

    final newMouseTracking = terminal.mouseTracking;
    if (newMouseTracking != _mouseTracking) {
      _mouseTracking = newMouseTracking;
      changed = true;
    }

    final newActiveScreen = terminal.activeScreen;
    if (newActiveScreen != _activeScreen) {
      _activeScreen = newActiveScreen;
      if (newActiveScreen == .primary) _applyModes();
      changed = true;
    }

    final newCursorKeyApp = terminal.modeGet(const .cursorKeys());
    if (newCursorKeyApp != _cursorKeyApplication) {
      _cursorKeyApplication = newCursorKeyApp;
      changed = true;
    }

    final newCursorBlinking =
        _config.cursorBlink ?? terminal.modeGet(const .cursorBlinking());
    if (newCursorBlinking != _cursorBlinking) {
      _cursorBlinking = newCursorBlinking;
      changed = true;
    }

    _scrollToBottomOnOutput();
    if (changed) notifyListeners();
  }

  void _onTextInput() {
    if (_config.selectionClearOnTyping) clearSelection();
    _scrollToBottomOnInput();
  }

  void _scrollToBottomOnInput() {
    if (_activeScreen == .alternate) return;
    final policy = _config.scrollToBottom;
    if (policy == .onKeystroke || policy == .both) scrollToBottom();
  }

  void _scrollToBottomOnOutput() {
    if (_activeScreen == .alternate) return;
    final policy = _config.scrollToBottom;
    if (policy == .onOutput || policy == .both) scrollToBottom();
  }

  bool _shouldRouteKeyThroughTextInput({
    required KeyAction action,
    required String? character,
    required String encoded,
    required Mods mods,
  }) {
    // Desktop printable keys are offered to Flutter text input only when the
    // terminal encoder produced the same literal character. Any protocol,
    // modifier, or composition-sensitive key stays on the terminal path.
    if (encoded != character) return false;
    if (_hasActiveComposition || !_textInput.isAttached) return false;
    if (!_isDesktopPlatform) return false;
    if (action != .press && action != .repeat) return false;
    if (!_virtualMods.isEmpty) return false;
    return !mods.hasCtrl && !mods.hasAlt && !mods.hasSuper;
  }

  Future<void> _updateKeyboardState(KeyboardState newState) async {
    if (newState == _keyboardState) return;
    _keyboardState = newState;

    switch (newState) {
      case .showing when hasFocus:
        _focusNode?.requestFocus();
        _textInput.show();
      case .showing:
        _focusNode?.requestFocus();
      case .hidden when hasFocus:
        _textInput.hide();
        _textInput.ensureAttached(keyboardAppearance: _brightness);
      case .hidden:
        _textInput.hide();
      case .disabled:
        _textInput.hide();
    }

    notifyListeners();
  }

  void _wireTerminalCallbacks() {
    terminal.onWritePty = _emitOutput;
    terminal.onBell = () => onBell?.call();
    terminal.onTitleChanged = () => onTitleChanged?.call();
    terminal.onColorScheme = () => _brightness == .light ? .light : .dark;
    terminal.onSize = _handleSizeQuery;
    terminal.onDeviceAttributes = () => _config.deviceAttributes;
    final enquiry = _config.enquiryResponse;
    terminal.onEnquiry = enquiry.isEmpty
        ? null
        : () => .fromList(utf8.encode(enquiry));
  }

  /// Filters out control characters and macOS function key private-use
  /// codepoints that should not be sent as UTF-8 text to the key encoder.
  static String? _encoderCharacter(String? character) {
    if (character == null || character.isEmpty) return null;
    final code = character.codeUnitAt(0);
    if (code < _space || code == _del) return null;
    if (code >= _macFunctionKeyStart && code <= _macFunctionKeyEnd) return null;
    return character;
  }
}
