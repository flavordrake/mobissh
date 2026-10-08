// Diagnostics section: visible "share crash report" + manual upload button.
//
// Lives under Settings → Advanced (a collapsed expander, #897/#966). Defensive
// contract: every interaction with [CrashReporter] is wrapped in try/catch so a
// UI tap can never crash the page.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../diagnostics/connect_trace.dart';
import '../diagnostics/crash_reporter.dart';
import '../diagnostics/feedback_bundle.dart';
import '../diagnostics/feedback_outbox.dart';
import '../diagnostics/frame_stats.dart' show frameStatsSnapshot;
import '../diagnostics/gesture_trace.dart';
import '../diagnostics/settings_snapshot.dart';
import '../storage/detection_exceptions_store.dart';
import 'connection_audit.dart';
import 'settings_subheader.dart';
import 'top_toast.dart';

class DiagnosticsSection extends StatefulWidget {
  /// Allows tests to inject a fake share function so we don't open the real
  /// platform share sheet.
  final Future<void> Function(File file)? onShare;

  /// Allows tests to intercept the assembled feedback-bundle text so we don't
  /// open the real platform share sheet (#553). Receives the assembled JSON
  /// blob. When null, production shares a temp `.json` file via share_plus.
  final Future<void> Function(String bundle)? onShareFeedback;

  /// #1257: whether the experimental developer tools (Force upload, Connection
  /// audit) render. Settings passes the "Show experimental settings" flag;
  /// standalone uses (tests) keep them.
  final bool experimental;

  /// #1259: the bug-report outbox; null = [FeedbackOutbox.instance].
  final FeedbackOutbox? outbox;

  const DiagnosticsSection({
    super.key,
    this.onShare,
    this.onShareFeedback,
    this.experimental = true,
    this.outbox,
  });

  @override
  State<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<DiagnosticsSection> {
  Future<_DiagnosticsSnapshot>? _future;

  // #1259: bug reports saved while offline. Loaded separately so outbox I/O
  // never holds up the crash rows.
  Future<OutboxStatus>? _outboxFuture;
  String? _outboxNote;
  bool _outboxBusy = false;

  FeedbackOutbox get _outbox => widget.outbox ?? FeedbackOutbox.instance;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _load();
      _outboxFuture = _outbox.status();
    });
  }

  Future<void> _sendOutboxNow() async {
    setState(() => _outboxBusy = true);
    final r = await _outbox.flush(auto: false);
    if (!mounted) return;
    setState(() {
      _outboxBusy = false;
      _outboxNote = r.skipped
          ? 'A send is already in progress.'
          : 'Sent ${r.sent}'
                '${r.failed > 0 ? '; ${r.failed} still waiting (offline?)' : ''}'
                '${r.rejected > 0 ? '; ${r.rejected} refused by the server' : ''}'
                '${r.expired > 0 ? '; ${r.expired} older than 30 days deleted' : ''}.';
    });
    _refresh();
  }

  Future<void> _discardOutbox() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard saved bug reports?'),
        content: const Text('They will not be sent.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            key: const ValueKey('outbox-discard-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _outbox.discardAll();
    if (!mounted) return;
    setState(() => _outboxNote = 'Saved bug reports discarded.');
    _refresh();
  }

  Widget _buildOutboxRow() {
    return FutureBuilder<OutboxStatus>(
      future: _outboxFuture,
      builder: (context, snap) {
        final s = snap.data ?? const OutboxStatus();
        if (s.total == 0 && _outboxNote == null) {
          return const SizedBox.shrink();
        }
        final extra = <String>[
          if (s.rejected > 0) '${s.rejected} refused by the server',
          if (s.unconfirmed > 0)
            '${s.unconfirmed} interrupted mid-upload (not resent)',
          if (s.corrupt > 0) '${s.corrupt} unreadable',
        ];
        return Column(
          key: const ValueKey('outbox-row'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.outbox_outlined),
              title: Text(
                s.pending == 1
                    ? '1 bug report waiting to send'
                    : '${s.pending} bug reports waiting to send',
                key: const ValueKey('outbox-status'),
              ),
              subtitle: Text(
                [...extra, ?_outboxNote].join(' · '),
                key: const ValueKey('outbox-note'),
              ),
            ),
            if (s.total > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      key: const ValueKey('outbox-send-now'),
                      onPressed: _outboxBusy || s.pending == 0
                          ? null
                          : _sendOutboxNow,
                      child: const Text('Send now'),
                    ),
                    TextButton(
                      key: const ValueKey('outbox-discard'),
                      onPressed: _outboxBusy ? null : _discardOutbox,
                      child: const Text('Discard'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Future<_DiagnosticsSnapshot> _load() async {
    final count = await CrashReporter.pendingCrashCount();
    final latest = await CrashReporter.latestCrashFile();
    return _DiagnosticsSnapshot(pendingCount: count, latest: latest);
  }

  Future<void> _share(File file) async {
    try {
      final handler = widget.onShare;
      if (handler != null) {
        await handler(file);
        return;
      }
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'MobiSSH crash report',
        text: 'Crash report from MobiSSH (#501).',
      );
    } catch (err) {
      if (!mounted) return;
      showTopToast(context, 'Share failed: $err');
    }
  }

  /// Assemble the full feedback bundle (connect log + last crash + env +
  /// version/git-hash + device/OS) and share it off the device (#553).
  ///
  /// This is the OFFLINE BACKUP path (#673): the integrated in-app Feedback
  /// overlay (#664) is the primary route but needs prod/Tailscale reachable.
  /// This share-sheet path is the only way to get a feedback bundle off the
  /// device (email/files) when the network is unavailable.
  ///
  /// Defensive: any failure surfaces a toast instead of crashing the form.
  Future<void> _shareFeedback() async {
    try {
      final info = await CrashReporter.environmentSnapshot();
      final crashJson = await CrashReporter.latestCrashContent();
      // #995: the saved "Not a URL"/"Not a file" reports ride along (count +
      // recent) so recurring false-positive classes can become detector fixes.
      // Best-effort: a storage hiccup must not block the share path.
      List<String> exceptionLines = const <String>[];
      try {
        final exceptions = await DetectionExceptionsStore().load();
        exceptionLines = [
          for (final e in exceptions)
            '${e.matchedText} [${e.patternId}]'
                '${e.host.isNotEmpty ? ' host=${e.host}' : ''}'
                '${e.tsMs > 0 ? ' ts=${DateTime.fromMillisecondsSinceEpoch(e.tsMs, isUtc: true).toIso8601String()}' : ''}'
                '${e.contextLine.isNotEmpty ? ' line=${e.contextLine}' : ''}',
        ];
      } catch (_) {
        // Bundle ships without the corpus rather than not at all.
      }
      final bundle = assembleFeedbackBundle(
        info: info,
        connectLog: connectLogSnapshot(),
        gestureLog: gestureLogSnapshot(),
        lifecycleLog: lifecycleLogSnapshot(),
        detectionExceptions: exceptionLines,
        // #1135: frame timing + viewport + session load. The share path is the
        // only route off the device when the network is down, so it carries the
        // same section the upload does.
        frameStats: frameStatsSnapshot(),
        settings: await settingsSnapshot(),
        crashJson: crashJson,
      );

      final handler = widget.onShareFeedback;
      if (handler != null) {
        await handler(bundle);
        return;
      }

      // Write to a temp .json file so the share sheet offers a real attachment
      // (email, Drive, etc.) rather than a giant inline text payload.
      final dir = Directory.systemTemp;
      final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'mobissh-feedback-$stamp.json',
      );
      await file.writeAsString(bundle);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'MobiSSH feedback',
        text: 'MobiSSH feedback bundle (#553): connect log + diagnostics.',
      );
    } catch (err) {
      if (!mounted) return;
      showTopToast(context, 'Share feedback failed: $err');
    }
  }

  Future<void> _forceUpload() async {
    UploadSummary summary;
    try {
      summary = await CrashReporter.uploadPending();
    } catch (err) {
      summary = const UploadSummary();
      if (mounted) {
        showTopToast(context, 'Upload failed: $err');
      }
    }
    if (mounted) {
      showTopToast(context, summary.toString());
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DiagnosticsSnapshot>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        final pending = data?.pendingCount ?? 0;
        final latest = data?.latest;
        // #897: flattened — no longer a self-collapsing ExpansionTile. The
        // section is composed directly into the Settings page under a
        // 'Diagnostics' subheader; the pending-crash count moves from the old
        // tile subtitle to a live status line. The 'diagnostics-section' key is
        // retained on the root so existing tests / screenshots still address it.
        return Column(
          key: const ValueKey('diagnostics-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsSubheader('Diagnostics'),
            ListTile(
              key: const ValueKey('diagnostics-pending-status'),
              leading: const Icon(Icons.bug_report_outlined),
              title: Text(
                pending == 0
                    ? 'No crashes pending upload.'
                    : '$pending crash report${pending == 1 ? '' : 's'} pending upload.',
              ),
            ),
            _buildOutboxRow(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('share-feedback-button'),
                    onPressed: _shareFeedback,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share feedback (offline backup)'),
                  ),
                  const Padding(
                    key: ValueKey('share-feedback-caption'),
                    padding: EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      'Offline backup — the in-app Feedback button is the '
                      'primary path.',
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (latest != null)
                    OutlinedButton.icon(
                      key: const ValueKey('share-last-crash-button'),
                      onPressed: () => _share(latest),
                      icon: const Icon(Icons.share),
                      label: const Text('Share last crash report'),
                    ),
                  if (latest == null)
                    const Text(
                      'No crash report on disk.',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  if (widget.experimental) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('force-upload-button'),
                    onPressed: _forceUpload,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Force upload pending crashes'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('connection-audit-button'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ConnectionAuditScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.show_chart),
                    label: const Text('Connection Audit'),
                  ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DiagnosticsSnapshot {
  final int pendingCount;
  final File? latest;

  const _DiagnosticsSnapshot({required this.pendingCount, this.latest});
}
