// #1141 (PR C of #1117) — `mobissh://` link dialogs.
//
// R12 confirmation: names the profile (title, host, user) with `Connect once`
// and `Always allow links to open <title>`; with a verb it also names the
// exact command that will run (R16, #1149). R14 picker: lists ONLY the R9
// candidates; the router always confirms afterwards. R23(b) run dialog: a
// live session never receives a verb until this is tapped (#1149).
//
// #1279 G1 / F8 tap-through guard: a link can make a dialog appear under a
// finger that was already coming down on something else. The buttons that
// ACCEPT (Connect once, Always allow, Run) stay disabled for
// [linkDialogArmDelay] after the dialog is shown; Cancel is live at once.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/connect_link_router.dart';
import '../services/link_verb.dart';
import '../storage/profiles_store.dart';

/// How long the accepting buttons of a link dialog stay inert (F8).
const Duration linkDialogArmDelay = Duration(milliseconds: 400);

String _titleOf(SavedProfile profile) =>
    profile.title.isEmpty ? profile.host : profile.title;

/// Builds [builder] with `armed == false` until [linkDialogArmDelay] has
/// passed since this widget was first shown.
class _ArmAfterDelay extends StatefulWidget {
  const _ArmAfterDelay({required this.builder});
  final Widget Function(BuildContext context, bool armed) builder;

  @override
  State<_ArmAfterDelay> createState() => _ArmAfterDelayState();
}

class _ArmAfterDelayState extends State<_ArmAfterDelay> {
  bool _armed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(linkDialogArmDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _armed);
}

Future<LinkConfirmChoice?> showLinkConfirmDialog(
  BuildContext context,
  SavedProfile profile, {
  LinkVerbCommand? verb,
}) {
  final title = _titleOf(profile);
  return showDialog<LinkConfirmChoice>(
    context: context,
    builder: (_) => _ArmAfterDelay(builder: (ctx, armed) => AlertDialog(
      key: const Key('link-confirm-dialog'),
      title: Text('Open $title from a link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${profile.username}@${profile.host}:${profile.port}'),
          if (verb != null) ...[
            const SizedBox(height: 12),
            const Text('Then run:'),
            Text(
              verb.commandLine,
              key: const Key('link-confirm-command'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('link-confirm-cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('link-confirm-always'),
          onPressed: armed
              ? () => Navigator.of(ctx).pop(LinkConfirmChoice.always)
              : null,
          child: Text('Always allow links to open $title'),
        ),
        FilledButton(
          key: const Key('link-confirm-once'),
          onPressed: armed
              ? () => Navigator.of(ctx).pop(LinkConfirmChoice.once)
              : null,
          child: const Text('Connect once'),
        ),
      ],
    )),
  );
}

/// R23(b): a link verb for a session that is ALREADY live is sent only after
/// the user reads the exact command in the terminal and taps Run — the bytes
/// land wherever the PTY's foreground is, so `linkAutoConnect` does not skip
/// this. Resolves true on Run, false on Cancel / dismiss.
Future<bool> showLinkVerbRunDialog(
  BuildContext context,
  SavedProfile profile,
  LinkVerbCommand verb,
) async {
  final title = _titleOf(profile);
  final run = await showDialog<bool>(
    context: context,
    builder: (_) => _ArmAfterDelay(builder: (ctx, armed) => AlertDialog(
      key: const Key('link-verb-run-dialog'),
      title: Text('Run in $title?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('A link asks to type this into the open session:'),
          const SizedBox(height: 12),
          Text(
            verb.commandLine,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('link-verb-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('link-verb-run'),
          onPressed: armed ? () => Navigator.of(ctx).pop(true) : null,
          child: const Text('Run'),
        ),
      ],
    )),
  );
  return run ?? false;
}

Future<SavedProfile?> showLinkPickerDialog(
  BuildContext context,
  List<SavedProfile> candidates,
) {
  return showDialog<SavedProfile>(
    context: context,
    builder: (ctx) => SimpleDialog(
      key: const Key('link-picker-dialog'),
      title: const Text('Which profile?'),
      children: [
        for (final p in candidates)
          SimpleDialogOption(
            key: Key('link-pick-${p.identityKey}'),
            onPressed: () => Navigator.of(ctx).pop(p),
            child: ListTile(
              title: Text(p.title.isEmpty ? p.host : p.title),
              subtitle: Text('${p.username}@${p.host}:${p.port}'),
            ),
          ),
      ],
    ),
  );
}
