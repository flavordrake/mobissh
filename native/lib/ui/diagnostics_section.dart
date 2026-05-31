// Diagnostics section: visible "share crash report" + manual upload button.
//
// Lives at the bottom of the Connect form. Defensive contract: every
// interaction with [CrashReporter] is wrapped in try/catch so a UI tap can
// never crash the form.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../diagnostics/connect_trace.dart';
import '../diagnostics/crash_reporter.dart';
import '../diagnostics/feedback_bundle.dart';
import 'connection_audit.dart';

class DiagnosticsSection extends StatefulWidget {
  /// Allows tests to inject a fake share function so we don't open the real
  /// platform share sheet.
  final Future<void> Function(File file)? onShare;

  /// Allows tests to intercept the assembled feedback-bundle text so we don't
  /// open the real platform share sheet (#553). Receives the assembled JSON
  /// blob. When null, production shares a temp `.json` file via share_plus.
  final Future<void> Function(String bundle)? onShareFeedback;

  const DiagnosticsSection({super.key, this.onShare, this.onShareFeedback});

  @override
  State<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<DiagnosticsSection> {
  Future<_DiagnosticsSnapshot>? _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Share failed: $err')));
    }
  }

  /// Assemble the full feedback bundle (connect log + last crash + env +
  /// version/git-hash + device/OS) and share it off the device (#553).
  ///
  /// Defensive: any failure surfaces a snackbar instead of crashing the form.
  /// Network is never blocking — the share sheet is the primary path; an
  /// optional upload is fire-and-forget elsewhere.
  Future<void> _shareFeedback() async {
    try {
      final info = await CrashReporter.environmentSnapshot();
      final crashJson = await CrashReporter.latestCrashContent();
      final bundle = assembleFeedbackBundle(
        info: info,
        connectLog: connectLogSnapshot(),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Share feedback failed: $err')));
    }
  }

  Future<void> _forceUpload() async {
    UploadSummary summary;
    try {
      summary = await CrashReporter.uploadPending();
    } catch (err) {
      summary = const UploadSummary();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $err')));
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(summary.toString())));
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
        return ExpansionTile(
          key: const ValueKey('diagnostics-section'),
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Diagnostics'),
          subtitle: Text(
            pending == 0
                ? 'No crashes pending upload.'
                : '$pending crash report${pending == 1 ? '' : 's'} pending upload.',
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('share-feedback-button'),
                    onPressed: _shareFeedback,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share feedback'),
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
                  const SizedBox(height: 8),
                  const _ConnectLogTile(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Expandable tile that surfaces the in-memory connect-trace ring buffer
/// (#543) so connect issues can be diagnosed on-device without Termux/adb.
class _ConnectLogTile extends StatelessWidget {
  const _ConnectLogTile();

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      key: const ValueKey('connect-log-tile'),
      leading: const Icon(Icons.terminal),
      title: const Text('Connect log'),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        ValueListenableBuilder<List<String>>(
          valueListenable: connectLog,
          builder: (context, lines, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  key: const ValueKey('connect-log-output'),
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: lines.isEmpty
                      ? const Text(
                          'No connect trace yet. Start a connection.',
                          style: TextStyle(fontStyle: FontStyle.italic),
                        )
                      : SingleChildScrollView(
                          reverse: true,
                          child: Text(
                            lines.join('\n'),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('connect-log-copy-button'),
                        onPressed: lines.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: lines.join('\n')),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Connect log copied.'),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('connect-log-clear-button'),
                        onPressed: lines.isEmpty ? null : clearConnectLog,
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear'),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _DiagnosticsSnapshot {
  final int pendingCount;
  final File? latest;

  const _DiagnosticsSnapshot({required this.pendingCount, this.latest});
}
