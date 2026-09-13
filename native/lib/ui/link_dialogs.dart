// #1141 (PR C of #1117) — `mobissh://` link dialogs.
//
// R12 confirmation: names the profile (title, host, user) with `Connect once`
// and `Always allow links to open <title>`. R14 picker: lists ONLY the R9
// candidates; the router always confirms afterwards.

import 'package:flutter/material.dart';

import '../services/connect_link_router.dart';
import '../storage/profiles_store.dart';

Future<LinkConfirmChoice?> showLinkConfirmDialog(
  BuildContext context,
  SavedProfile profile,
) {
  final title = profile.title.isEmpty ? profile.host : profile.title;
  return showDialog<LinkConfirmChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('link-confirm-dialog'),
      title: Text('Open $title from a link?'),
      content: Text('${profile.username}@${profile.host}:${profile.port}'),
      actions: [
        TextButton(
          key: const Key('link-confirm-cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('link-confirm-always'),
          onPressed: () => Navigator.of(ctx).pop(LinkConfirmChoice.always),
          child: Text('Always allow links to open $title'),
        ),
        FilledButton(
          key: const Key('link-confirm-once'),
          onPressed: () => Navigator.of(ctx).pop(LinkConfirmChoice.once),
          child: const Text('Connect once'),
        ),
      ],
    ),
  );
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
