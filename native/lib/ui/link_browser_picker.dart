// The browser picker (#1197 — slice 2 of #1195). Spec:
// `docs/link-browser-routing.md` R6/R7/R13, test A8.
//
// ONE widget serves BOTH surfaces — Settings' global default and the profile
// editor's per-profile override — because they differ only in their "default"
// option's label and in what they persist. A second implementation would be a
// second place for the two lists to drift apart.
//
// A8 / the #1153-slice-1 rule: an EMPTY enumeration hides the control
// ENTIRELY. A host with no channel (desktop, tests) or a device that somehow
// enumerates nothing gets no dead affordance, not an empty dropdown.
//
// Monochrome Material glyph, never an emoji
// (feedback_monochrome_icons_no_emoji).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/browser_targets.dart';
import '../services/link_browser_router.dart';

class LinkBrowserPicker extends ConsumerWidget {
  const LinkBrowserPicker({
    super.key,
    required this.pickerKey,
    required this.label,
    required this.defaultLabel,
    required this.value,
    required this.onChanged,
  });

  /// Key on the [DropdownButton] itself, so a test addresses the control
  /// rather than its decoration.
  final Key pickerKey;

  /// Field label ('Browser for links').
  final String label;

  /// The null option's label — 'System default' globally, 'Use the global
  /// default' per profile.
  final String defaultLabel;

  /// The stored PACKAGE (never a label, D2); null = [defaultLabel].
  final String? value;

  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets =
        ref.watch(browserTargetsListProvider).valueOrNull ??
        const <BrowserTarget>[];
    // A8: nothing to choose between → no control at all.
    if (targets.isEmpty) return const SizedBox.shrink();

    // R12: a stored package that no longer enumerates has no item to select.
    // Show the DEFAULT option rather than crashing the dropdown — the stored
    // value is untouched; only the next explicit pick rewrites it.
    final packages = targets.map((t) => t.package).toSet();
    final selected = packages.contains(value) ? value : null;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.open_in_browser_outlined),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          key: pickerKey,
          isExpanded: true,
          value: selected,
          items: [
            DropdownMenuItem<String?>(child: Text(defaultLabel)),
            for (final target in targets)
              DropdownMenuItem<String?>(
                value: target.package,
                child: Text(target.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
