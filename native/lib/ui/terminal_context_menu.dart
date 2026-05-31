// Terminal long-press context menu (#568, Phase 2).
//
// xterm.dart's `TerminalView` exposes `onSecondaryTapDown`, which fires on a
// long-press (touch) or right-click (pointer). We use it to surface a minimal
// Material popup near the press point with Copy / Select all / Paste.
//
// HARD CONSTRAINT (from the gesture design + the PWA's 5-cycle selection
// disaster): we do NOT build a selection overlay or drag-to-extend selection.
// Selection rendering stays entirely xterm.dart's domain. This menu only
// READS the current selection (`terminal.buffer.getText(controller.selection)`)
// and drives the controller's own `setSelection` / `clearSelection`. No custom
// canvas, no mirrored selection state — nothing to desync.

import 'package:flutter/material.dart';

/// The three actions the terminal context menu can offer. Built by the
/// terminal body from a session's `TerminalController` + `Terminal` + proxy so
/// this widget stays free of xterm/riverpod dependencies and is trivially
/// unit-testable.
class TerminalContextMenuActions {
  const TerminalContextMenuActions({
    required this.hasSelection,
    required this.onCopy,
    required this.onSelectAll,
    required this.onPaste,
  });

  /// Whether the terminal currently has a non-empty selection. When false the
  /// Copy item is omitted (nothing to copy).
  final bool hasSelection;

  /// Copy the current selection to the clipboard.
  final VoidCallback onCopy;

  /// Select the whole terminal buffer.
  final VoidCallback onSelectAll;

  /// Paste the clipboard contents into the active session.
  final VoidCallback onPaste;
}

/// Item identifiers for the popup. Public so widget tests can address them by
/// key without matching on label text.
enum TerminalContextMenuItem { copy, selectAll, paste }

/// Show the terminal context menu at [globalPosition]. Returns once the menu
/// is dismissed. The chosen action's callback is invoked here so callers don't
/// have to branch on the result.
Future<void> showTerminalContextMenu(
  BuildContext context, {
  required Offset globalPosition,
  required TerminalContextMenuActions actions,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final overlaySize = overlay?.size ?? MediaQuery.of(context).size;

  final position = RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    overlaySize.width - globalPosition.dx,
    overlaySize.height - globalPosition.dy,
  );

  final selected = await showMenu<TerminalContextMenuItem>(
    context: context,
    position: position,
    items: [
      if (actions.hasSelection)
        const PopupMenuItem<TerminalContextMenuItem>(
          key: Key('terminal-ctx-copy'),
          value: TerminalContextMenuItem.copy,
          child: Text('Copy'),
        ),
      const PopupMenuItem<TerminalContextMenuItem>(
        key: Key('terminal-ctx-select-all'),
        value: TerminalContextMenuItem.selectAll,
        child: Text('Select all'),
      ),
      const PopupMenuItem<TerminalContextMenuItem>(
        key: Key('terminal-ctx-paste'),
        value: TerminalContextMenuItem.paste,
        child: Text('Paste'),
      ),
    ],
  );

  switch (selected) {
    case TerminalContextMenuItem.copy:
      actions.onCopy();
      break;
    case TerminalContextMenuItem.selectAll:
      actions.onSelectAll();
      break;
    case TerminalContextMenuItem.paste:
      actions.onPaste();
      break;
    case null:
      break;
  }
}
