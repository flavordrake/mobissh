// Shared Download + Share app-bar actions for every file viewer (#1038).
//
// One widget, dropped into each viewer's AppBar (and the tap-to-fill viewer's
// overlay), so viewers can't drift: the registry drift-guard test asserts its
// presence for every registered viewer type. Monochrome Material glyphs (no
// emoji), standard 48dp IconButton targets.
//
// While an action runs, its button becomes a small progress ring —
// determinate when the transfer reports a total (big files), indeterminate
// otherwise — and the other button is disabled (one transfer at a time,
// matching the browser's policy). Results surface as top toasts: "Saved to …"
// / failure messages; a successful share needs no toast (the sheet itself is
// the feedback).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/viewer_file_actions.dart';
import 'top_toast.dart';

enum _ViewerAction { download, share }

/// Download + Share buttons for [source]. Place in an AppBar's `actions` (or
/// any overlay row). [iconColor] overrides the theme color for dark-scrim
/// hosts (the fill viewer).
class FileViewerActions extends ConsumerStatefulWidget {
  const FileViewerActions({super.key, required this.source, this.iconColor});

  final ViewerFileSource source;
  final Color? iconColor;

  @override
  ConsumerState<FileViewerActions> createState() => _FileViewerActionsState();
}

class _FileViewerActionsState extends ConsumerState<FileViewerActions> {
  _ViewerAction? _busy;
  int _received = 0;
  int? _total;

  void _onProgress(int received, int? total) {
    if (!mounted) return;
    setState(() {
      _received = received;
      _total = total;
    });
  }

  Future<void> _run(_ViewerAction action) async {
    if (_busy != null) return; // one transfer at a time
    setState(() {
      _busy = action;
      _received = 0;
      _total = null;
    });
    final service = ref.read(fileViewerActionServiceProvider);
    try {
      switch (action) {
        case _ViewerAction.download:
          final location = await service.downloadToDevice(
            widget.source,
            onProgress: _onProgress,
          );
          if (mounted) showTopToast(context, 'Saved to $location');
        case _ViewerAction.share:
          await service.shareFile(widget.source, onProgress: _onProgress);
        // No success toast — the share sheet itself is the feedback.
      }
    } catch (e) {
      if (mounted) {
        final verb = action == _ViewerAction.download ? 'Download' : 'Share';
        showTopToast(context, '$verb failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _button(_ViewerAction action) {
    if (_busy == action) {
      final t = _total;
      final value = (t != null && t > 0)
          ? (_received / t).clamp(0.0, 1.0)
          : null;
      return SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 2.5,
              color: widget.iconColor,
            ),
          ),
        ),
      );
    }
    final isDownload = action == _ViewerAction.download;
    return IconButton(
      key: Key(
        isDownload ? 'viewer-action-download' : 'viewer-action-share',
      ),
      tooltip: isDownload ? 'Download' : 'Share',
      icon: Icon(
        isDownload ? Icons.download : Icons.share,
        color: widget.iconColor,
      ),
      onPressed: _busy == null ? () => unawaited(_run(action)) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(_ViewerAction.download),
        _button(_ViewerAction.share),
      ],
    );
  }
}
