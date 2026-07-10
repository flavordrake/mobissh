// URL action overlay (#570 "copy & navigate URLs" — Slice 1).
//
// On a long-press that lands on a detected terminal URL, show:
//   * a transient HIGHLIGHT over the URL's on-screen cell rect(s) (a
//     soft-wrapped URL spans multiple rendered rows → multiple rects), and
//   * a small popup menu with COPY and OPEN actions.
//
// Copy → Clipboard.setData + a top toast confirmation (NOT a bottom SnackBar —
// that covers the keybar/compose bar, see top_toast.dart). Open → url_launcher
// in externalApplication mode (the real browser); injectable for tests so the
// widget test never hits a real browser.
//
// The overlay dismisses on: an action tap, a tap outside the menu, or a short
// timeout. Implemented as a single root-overlay OverlayEntry so it floats above
// the route and any keyboard; only one is live at a time.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/clipboard.dart';
import 'top_toast.dart';

/// Pluggable URL opener so the widget test can assert "Open was invoked with
/// this URL" without launching a real browser. Returns true on success.
typedef UrlOpener = Future<bool> Function(String url);

/// Default opener: the system browser via url_launcher, external application.
Future<bool> _defaultOpen(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Test seam: overrides the opener used by [showUrlActions] when non-null.
@visibleForTesting
UrlOpener? debugUrlOpenerOverride;

/// Open [url] in the external browser, honouring [debugUrlOpenerOverride] (#955).
///
/// The shared open path for BOTH the long-press action overlay and the gutter
/// list-sheet's URL "Open" item, so test injection covers both. Returns true on
/// success.
Future<bool> openDetectedUrl(String url) =>
    (debugUrlOpenerOverride ?? _defaultOpen)(url);

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
void debugDismissUrlActions() => _dismiss();

/// Show the Copy/Open action menu + transient highlight for [url].
///
/// [highlightRects] are the URL's on-screen cell rectangles in GLOBAL
/// coordinates (one per rendered row the URL spans). [anchor] is the global
/// point the menu is positioned near (typically the long-press location).
///
/// [onMarkNotDetection] (#995): when non-null a LAST "Not a URL" item is
/// offered (destructive-adjacent placement) — tapping dismisses the menu and
/// fires the callback (the caller persists the detection exception).
///
/// [showOpen] / [notLabel] (#1031 slice 3): a USER-DEFINED pattern's match is
/// an arbitrary token, not a URL — its menu drops the Open action and labels
/// the report item "Not a match". Defaults keep the URL menu exactly as-is.
///
/// Safe to call from any context under an [Overlay]. No-op if no overlay.
void showUrlActions(
  BuildContext context,
  String url, {
  required List<Rect> highlightRects,
  required Offset anchor,
  VoidCallback? onMarkNotDetection,
  bool showOpen = true,
  String notLabel = 'Not a URL',
  Duration timeout = const Duration(seconds: 6),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _dismiss();

  final opener = debugUrlOpenerOverride ?? _defaultOpen;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _UrlActionLayer(
      url: url,
      highlightRects: highlightRects,
      anchor: anchor,
      onCopy: () {
        // copyToClipboard is async (native channel write + read-back verify),
        // but onCopy is a synchronous VoidCallback. Dismiss the menu now and
        // toast only once the (verified) write completes.
        unawaited(() async {
          final ok = await copyToClipboard(url);
          if (identical(_activeEntry, entry)) _dismiss();
          if (ok) showTopToastInOverlay(overlay, 'Copied: $url');
        }());
      },
      onOpen: () async {
        if (identical(_activeEntry, entry)) _dismiss();
        final ok = await opener(url);
        if (!ok) {
          showTopToastInOverlay(overlay, 'Could not open: $url');
        }
      },
      onDismiss: () {
        if (identical(_activeEntry, entry)) _dismiss();
      },
      showOpen: showOpen,
      notLabel: notLabel,
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
class _UrlActionLayer extends StatelessWidget {
  const _UrlActionLayer({
    required this.url,
    required this.highlightRects,
    required this.anchor,
    required this.onCopy,
    required this.onOpen,
    required this.onDismiss,
    this.onMarkNotDetection,
    this.showOpen = true,
    this.notLabel = 'Not a URL',
  });

  final String url;
  final List<Rect> highlightRects;
  final Offset anchor;
  final VoidCallback onCopy;
  final Future<void> Function() onOpen;
  final VoidCallback onDismiss;

  /// #995: persists a "Not a URL" detection exception; null hides the item.
  final VoidCallback? onMarkNotDetection;

  /// #1031 slice 3: false for a user-defined match (no browser Open).
  final bool showOpen;

  /// #1031 slice 3: "Not a match" for a user-defined pattern's report item.
  final String notLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final accent = theme.colorScheme.primary;

    // Position the menu just below the lowest highlight rect (or the anchor),
    // clamped within the screen so it never runs off the bottom/edges.
    final below = highlightRects.isEmpty
        ? anchor.dy + 24
        : highlightRects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b) +
              8;
    // The card sizes to its content (intrinsic); these are the layout estimates
    // used only to anchor + clamp the position so it never runs off-screen.
    const estMenuWidth = 220.0;
    const menuHeight = 56.0;
    var left = anchor.dx - estMenuWidth / 2;
    left = left.clamp(8.0, math.max(8.0, media.size.width - estMenuWidth - 8));
    var top = below;
    if (top + menuHeight > media.size.height - 8) {
      // No room below — place above the highlight.
      final aboveTop = highlightRects.isEmpty
          ? anchor.dy - menuHeight - 24
          : highlightRects.map((r) => r.top).reduce((a, b) => a < b ? a : b) -
                menuHeight -
                8;
      top = aboveTop.clamp(8.0, media.size.height - menuHeight - 8);
    }

    return Stack(
      children: [
        // Tap-outside scrim (transparent) — dismiss without consuming nothing
        // else. Behaves as a full-screen catcher behind the menu.
        Positioned.fill(
          child: GestureDetector(
            key: const Key('url-action-scrim'),
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        // Transient highlight over the URL's cell rects.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _UrlHighlightPainter(
                rects: highlightRects,
                color: accent,
              ),
            ),
          ),
        ),
        // The action menu card.
        Positioned(
          left: left,
          top: top,
          child: Material(
            key: const Key('url-action-menu'),
            color: theme.colorScheme.surfaceContainerHighest,
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            // Intrinsic width: the Row sizes to its two buttons (a fixed width
            // overflowed by a few px depending on text metrics). Clamp the max
            // so a future longer label can't run off-screen.
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(media.size.width - 16, 320),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                // Wrap, not Row (#995): with the third "Not a URL" item the
                // buttons can exceed the max width — they flow to a second
                // line instead of overflowing (mirrors the path overlay).
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _ActionButton(
                      key: const Key('url-action-copy'),
                      icon: Icons.content_copy,
                      label: 'Copy',
                      onTap: onCopy,
                    ),
                    if (showOpen)
                      _ActionButton(
                        key: const Key('url-action-open'),
                        icon: Icons.open_in_new,
                        label: 'Open',
                        onTap: () {
                          onOpen();
                        },
                      ),
                    // #995: LAST (destructive-adjacent) — report false positive.
                    if (onMarkNotDetection != null)
                      _ActionButton(
                        key: const Key('url-action-not-url'),
                        icon: notLabel == 'Not a URL'
                            ? Icons.link_off
                            : Icons.search_off,
                        label: notLabel,
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

/// Paints a translucent rounded highlight over each URL cell rect.
class _UrlHighlightPainter extends CustomPainter {
  _UrlHighlightPainter({required this.rects, required this.color});

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
  bool shouldRepaint(_UrlHighlightPainter old) =>
      old.rects != rects || old.color != color;
}
