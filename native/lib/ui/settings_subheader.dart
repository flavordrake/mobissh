// Light, non-collapsing group label for the flat Settings page (#897).
//
// Replaces the old self-collapsing ExpansionTile group wrappers: instead of
// hiding controls behind a tap, each group is introduced by a small uppercase-y
// primary-colored label and every control under it is always visible. Used by
// both [SettingsPanel] (General / Background / Terminal / Detection) and
// [DiagnosticsSection] (Diagnostics).

import 'package:flutter/material.dart';

class SettingsSubheader extends StatelessWidget {
  const SettingsSubheader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
