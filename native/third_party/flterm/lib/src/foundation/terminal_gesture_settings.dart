import 'package:flutter/foundation.dart';

import 'terminal_selection.dart';

/// A modifier key used to trigger gesture behaviors.
///
/// Used by [TerminalGestureSettings.blockSelectionModifier] to choose
/// which held key switches from normal to block selection during drag.
enum GestureModifier { alt, control, meta, shift }

/// How triple-click line selection determines the end column.
///
/// Configures the trailing edge behavior when the gesture detector
/// resolves a line selection via [TerminalGestureSettings.lineSelectMode].
enum LineSelectMode {
  /// Selection ends at the last non-empty cell, trimming trailing blanks.
  content,

  /// Selection extends to the full row width regardless of content.
  full,
}

/// A type of selection gesture recognized by the gesture detector.
///
/// Each gesture maps to a distinct user interaction pattern. Disable
/// individual gestures via [TerminalGestureSettings.enabledSelections].
///
/// ```dart
/// // Disable drag selection, keep word and line selection.
/// TerminalGestureSettings(
///   enabledSelections: {SelectionGesture.word, SelectionGesture.line},
/// )
/// ```
enum SelectionGesture {
  /// Click and drag on desktop.
  drag,

  /// Double-tap to select a word.
  word,

  /// Triple-tap to select a logical line (follows soft wraps).
  line,

  /// Long press on touch devices.
  longPress,

  /// Select all via keyboard shortcut (Cmd+A on macOS, Ctrl+A elsewhere).
  selectAll;

  /// All recognized selection gestures.
  static const all = <SelectionGesture>{
    .drag,
    .word,
    .line,
    .longPress,
    .selectAll,
  };
}

/// Controls which selection gestures are enabled and how they behave.
///
/// Passed to [TerminalView.gestureSettings]. Only affects selection
/// behavior: mouse tracking (for terminal programs) and focus gestures
/// work regardless of these settings.
///
/// ```dart
/// TerminalView(
///   controller: controller,
///   gestureSettings: TerminalGestureSettings(
///     enabledSelections: {SelectionGesture.word, SelectionGesture.line},
///     blockSelectionModifier: GestureModifier.meta,
///   ),
/// )
/// ```
@immutable
final class TerminalGestureSettings {
  /// Which selection gestures are active.
  ///
  /// Defaults to [SelectionGesture.all]. Pass an empty set to disable
  /// text selection entirely while keeping mouse tracking and focus
  /// functional.
  final Set<SelectionGesture> enabledSelections;

  /// How triple-click line selection determines the end column.
  ///
  /// [LineSelectMode.content] (default) trims trailing empty cells.
  /// [LineSelectMode.full] always selects the full row width, which
  /// is useful when pasting output where trailing whitespace matters.
  final LineSelectMode lineSelectMode;

  /// Modifier key that switches drag selection to block (rectangular) mode.
  ///
  /// Defaults to [GestureModifier.alt], matching most desktop terminals.
  /// Set to null to disable modifier-based block selection.
  ///
  /// Avoid [GestureModifier.shift]: Shift is used to bypass terminal
  /// mouse tracking, and the two behaviors would conflict.
  final GestureModifier? blockSelectionModifier;

  /// Selection mode used for long-press gestures on touch devices.
  ///
  /// Defaults to [TerminalSelectionMode.normal] for linear text selection.
  /// Set to [TerminalSelectionMode.block] to start a rectangular selection
  /// on long press.
  final TerminalSelectionMode longPressSelectionMode;

  const TerminalGestureSettings({
    this.lineSelectMode = .content,
    this.blockSelectionModifier = .alt,
    this.longPressSelectionMode = .normal,
    this.enabledSelections = SelectionGesture.all,
  });

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(enabledSelections),
    blockSelectionModifier,
    longPressSelectionMode,
    lineSelectMode,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalGestureSettings &&
          setEquals(enabledSelections, other.enabledSelections) &&
          blockSelectionModifier == other.blockSelectionModifier &&
          longPressSelectionMode == other.longPressSelectionMode &&
          lineSelectMode == other.lineSelectMode;
}
