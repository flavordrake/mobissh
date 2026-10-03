// Detection exceptions list (#995), reached from the Detection lab's
// "Exceptions (N)" row. #1257 moved it off the Settings main page, where the
// unbounded list grew the page by one row per saved report.
//
// Each entry is a saved "Not a URL" / "Not a file" / "Not a command" report:
// the suppressed text plus when/where it was reported, with a per-entry remove
// that restores detection. NOT cleared by Reset settings (user data).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/detection_exceptions_providers.dart';
import '../storage/detection_exceptions_store.dart';
import '../util/relative_time.dart';

class DetectionExceptionsScreen extends ConsumerWidget {
  const DetectionExceptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exceptions = ref.watch(detectionExceptionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Detection exceptions')),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('detection-exceptions-list'),
          children: [
            if (exceptions.isEmpty)
              const ListTile(
                key: ValueKey('detection-exceptions-empty'),
                leading: Icon(Icons.playlist_remove_outlined),
                title: Text('No exceptions'),
                subtitle: Text(
                  'Use "Not a URL" / "Not a file" / "Not a command" on a '
                  'detected item to stop detecting that exact text. Saved '
                  'reports appear here.',
                ),
              )
            else
              for (var i = 0; i < exceptions.length; i++)
                ListTile(
                  key: ValueKey('detection-exception-$i'),
                  leading: Icon(switch (exceptions[i].family) {
                    'path' => Icons.folder_off_outlined,
                    // #998 D: "Not a command" reports (family 'command').
                    'command' => Icons.terminal,
                    _ => Icons.link_off,
                  }),
                  title: Text(
                    exceptions[i].matchedText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_subtitle(exceptions[i])),
                  trailing: IconButton(
                    key: ValueKey('detection-exception-remove-$i'),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove exception (detect again)',
                    onPressed: () => ref
                        .read(detectionExceptionsProvider.notifier)
                        .removeException(exceptions[i]),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// "when · host", dropping whichever segment is unknown.
  String _subtitle(DetectionException e) {
    final when = formatRelative(e.tsMs > 0 ? e.tsMs ~/ 1000 : null);
    return [
      if (when.isNotEmpty) when,
      if (e.host.isNotEmpty) e.host,
    ].join(' · ');
  }
}
