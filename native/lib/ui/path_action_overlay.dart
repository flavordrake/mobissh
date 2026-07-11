// Path action overlay (#778, paths Slice 1) — the file-path analogue of
// url_action_overlay.dart.
//
// On a long-press that lands on a detected absolute file PATH, show:
//   * a transient HIGHLIGHT over the path's on-screen cell rect(s) (a
//     soft-wrapped path spans multiple rendered rows → multiple rects), and
//   * a small popup menu with OPEN (in the SFTP file explorer) and COPY PATH.
//
// Open → an injectable opener (the view passes one that calls openFileBrowser
// with the path as initialPath); injectable so the widget test never pushes a
// real route. Copy → Clipboard.setData + a top toast (NOT a bottom SnackBar —
// that covers the keybar/compose bar, see top_toast.dart).
//
// The overlay dismisses on: an action tap, a tap outside the menu, or a short
// timeout. Single root-overlay OverlayEntry, mirroring the URL overlay; only one
// is live at a time (it reuses the URL overlay's lifecycle, so opening one
// dismisses the other).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/clipboard.dart';
import 'top_toast.dart';

/// Pluggable path opener so the widget test can assert "Open was invoked with
/// this path" without pushing a route. Returns true on success.
typedef PathOpener = Future<bool> Function(String path);

/// Test seam: overrides the opener used by [showPathActions] when non-null.
@visibleForTesting
PathOpener? debugPathOpenerOverride;

/// The single live overlay entry, so a new long-press replaces the old one.
OverlayEntry? _activeEntry;
Timer? _activeTimer;

void _dismiss() {
  _activeTimer?.cancel();
  _activeTimer = null;
  _activeEntry?.remove();
  _activeEntry = null;
}

/// Test seam: tear down any live overlay + its auto-dismiss timer so a widget
/// test that leaves the menu open doesn't trip the "Timer still pending" check.
@visibleForTesting
void debugDismissPathActions() => _dismiss();

/// Show the Open/Copy action menu + transient highlight for [path].
///
/// [highlightRects] are the path's on-screen cell rectangles in GLOBAL
/// coordinates (one per rendered row). [anchor] is the global point the menu is
/// positioned near (typically the long-press location). [onOpen] performs the
/// explorer navigation; when null the [debugPathOpenerOverride] (tests) or a
/// no-op is used.
///
/// [sftpUrl] (#994): the canonical `sftp://user@host[:port]/path` form of the
/// path on its session's host. When non-null a third "Copy sftp URL" action is
/// offered (a file:// anchor's share/canonical form); the bare-path Copy stays
/// the primary copy for command-line pasting.
///
/// [onMarkNotDetection] (#995): when non-null a LAST "Not a file" item is
/// offered (destructive-adjacent placement) — tapping dismisses the menu and
/// fires the callback (the caller persists the detection exception).
///
/// [relativeText] (#1036): the ORIGINAL relative matched text for a
/// relative-path anchor whose [path] is the cwd-RESOLVED absolute. When
/// non-null an extra "Copy relative" action copies it verbatim; "Copy path"
/// stays the resolved absolute (and Open / sftp:// already use it).
///
/// Safe to call from any context under an [Overlay]. No-op if no overlay.
void showPathActions(
  BuildContext context,
  String path, {
  required List<Rect> highlightRects,
  required Offset anchor,
  Future<bool> Function(String path)? onOpen,
  String? sftpUrl,
  String? relativeText,
  VoidCallback? onMarkNotDetection,
  Duration timeout = const Duration(seconds: 6),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _dismiss();

  final opener =
      debugPathOpenerOverride ?? onOpen ?? ((String _) async => false);

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _PathActionLayer(
      path: path,
      highlightRects: highlightRects,
      anchor: anchor,
      onCopy: () {
        // Async native write + read-back verify (#845); onCopy is a sync
        // VoidCallback, so dismiss now and toast once the write completes.
        unawaited(() async {
          final ok = await copyToClipboard(path);
          if (identical(_activeEntry, entry)) _dismiss();
          if (ok) showTopToastInOverlay(overlay, 'Copied: $path');
        }());
      },
      // #994: the canonical sftp:// form, only for anchors that carry one.
      onCopySftp: sftpUrl == null
          ? null
          : () {
              unawaited(() async {
                final ok = await copyToClipboard(sftpUrl);
                if (identical(_activeEntry, entry)) _dismiss();
                if (ok) showTopToastInOverlay(overlay, 'Copied: $sftpUrl');
              }());
            },
      // #1036: the original relative text, only for relative-path anchors.
      onCopyRelative: relativeText == null
          ? null
          : () {
              unawaited(() async {
                final ok = await copyToClipboard(relativeText);
                if (identical(_activeEntry, entry)) _dismiss();
                if (ok) {
                  showTopToastInOverlay(overlay, 'Copied: $relativeText');
                }
              }());
            },
      onOpen: () async {
        if (identical(_activeEntry, entry)) _dismiss();
        final ok = await opener(path);
        if (!ok) {
          showTopToastInOverlay(overlay, 'Could not open: $path');
        }
      },
      onDismiss: () {
        if (identical(_activeEntry, entry)) _dismiss();
      },
      // #995: dismiss first, then report — the exception write regroups the
      // affordance layers, so the menu must not outlive its anchor.
      onMarkNotDetection: onMarkNotDetection == null
          ? null
          : () {
              if (identical(_activeEntry, entry)) _dismiss();
              onMarkNotDetection();
            },
    ),
  );
  _activeEntry = entry;
  overlay.insert(entry);

  _activeTimer = Timer(timeout, () {
    if (identical(_activeEntry, entry)) _dismiss();
  });
}

/// Full-screen layer: tap-outside scrim + highlight painter + action menu card.
class _PathActionLayer extends StatelessWidget {
  const _PathActionLayer({
    required this.path,
    required this.highlightRects,
    required this.anchor,
    required this.onCopy,
    required this.onOpen,
    required this.onDismiss,
    this.onCopySftp,
    this.onCopyRelative,
    this.onMarkNotDetection,
  });

  final String path;
  final List<Rect> highlightRects;
  final Offset anchor;
  final VoidCallback onCopy;
  final Future<void> Function() onOpen;
  final VoidCallback onDismiss;

  /// #994: copies the canonical sftp:// URL; null hides the action.
  final VoidCallback? onCopySftp;

  /// #1036: copies the ORIGINAL relative matched text; null hides the action.
  final VoidCallback? onCopyRelative;

  /// #995: persists a "Not a file" detection exception; null hides the item.
  final VoidCallback? onMarkNotDetection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final accent = theme.colorScheme.primary;

    final below = highlightRects.isEmpty
        ? anchor.dy + 24
        : highlightRects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b) +
              8;
    const estMenuWidth = 220.0;
    const menuHeight = 56.0;
    var left = anchor.dx - estMenuWidth / 2;
    left = left.clamp(8.0, math.max(8.0, media.size.width - estMenuWidth - 8));
    var top = below;
    if (top + menuHeight > media.size.height - 8) {
      final aboveTop = highlightRects.isEmpty
          ? anchor.dy - menuHeight - 24
          : highlightRects.map((r) => r.top).reduce((a, b) => a < b ? a : b) -
                menuHeight -
                8;
      top = aboveTop.clamp(8.0, media.size.height - menuHeight - 8);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('path-action-scrim'),
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _PathHighlightPainter(
                rects: highlightRects,
                color: accent,
              ),
            ),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            key: const Key('path-action-menu'),
            color: theme.colorScheme.surfaceContainerHighest,
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(media.size.width - 16, 320),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                // Wrap, not Row (#994): with the third "Copy sftp URL" action
                // the buttons can exceed the max width — they flow to a second
                // line instead of overflowing.
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _ActionButton(
                      key: const Key('path-action-open'),
                      icon: Icons.folder_open,
                      label: 'Open',
                      onTap: () {
                        onOpen();
                      },
                    ),
                    _ActionButton(
                      key: const Key('path-action-copy'),
                      icon: Icons.content_copy,
                      label: 'Copy path',
                      onTap: onCopy,
                    ),
                    // #1036: for a relative anchor, the original matched text
                    // (Copy path above copies the resolved absolute).
                    if (onCopyRelative != null)
                      _ActionButton(
                        key: const Key('path-action-copy-relative'),
                        icon: Icons.content_copy,
                        label: 'Copy relative',
                        onTap: onCopyRelative!,
                      ),
                    if (onCopySftp != null)
                      _ActionButton(
                        key: const Key('path-action-copy-sftp'),
                        icon: Icons.link,
                        label: 'Copy sftp URL',
                        onTap: onCopySftp!,
                      ),
                    // #995: LAST (destructive-adjacent) — report false positive.
                    if (onMarkNotDetection != null)
                      _ActionButton(
                        key: const Key('path-action-not-file'),
                        icon: Icons.folder_off_outlined,
                        label: 'Not a file',
                        onTap: onMarkNotDetection!,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// Paints a translucent rounded highlight over each path cell rect.
class _PathHighlightPainter extends CustomPainter {
  _PathHighlightPainter({required this.rects, required this.color});

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: 0.28);
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final r in rects) {
      final rr = RRect.fromRectAndRadius(
        r.inflate(1),
        const Radius.circular(3),
      );
      canvas.drawRRect(rr, fill);
      canvas.drawRRect(rr, stroke);
    }
  }

  @override
  bool shouldRepaint(_PathHighlightPainter old) =>
      old.rects != rects || old.color != color;
}
