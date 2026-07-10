// Detection Lab ROOT (#1031 slice 2) — the workbench route reached from the
// Settings Detection row (and a session-menu detection-glyph long-press, IA
// review change 7).
//
// Zone order per the reviewed IA: global (master + accent note) → one CARD per
// built-in pattern (enable switch bound to the SAME detectionSettingsProvider
// bit Settings flips, plus a MINI live preview rendered by the real painter/
// chip code) → the lab-wide reset at the BOTTOM (review change 4: destructive
// control out of the thumb-prime zone, matching the Settings Reset
// convention). Tapping a card opens its detail page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/custom_patterns_providers.dart';
import '../state/detection_providers.dart';
import '../state/detection_style_providers.dart';
import '../storage/custom_patterns_store.dart';
import 'detection_lab_detail_screen.dart';
import 'detection_lab_pattern_editor.dart';
import 'detection_lab_preview.dart';
import 'detection_style_resolver.dart';
import 'settings_subheader.dart';

export 'detection_lab_detail_screen.dart' show DetectionLabDetailScreen;
export 'detection_lab_pattern_editor.dart'
    show DetectionLabPatternEditorScreen;
export 'detection_lab_preview.dart'
    show
        DetectionLabPatternSpec,
        DetectionPreviewLine,
        detectionLabPatternSpec,
        detectionLabPatternSpecs,
        detectionLabSpecForCustomPattern;

class DetectionLabScreen extends ConsumerWidget {
  const DetectionLabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final detection = ref.watch(detectionSettingsProvider);
    final styles = ref.watch(detectionStylesProvider);
    final customPatterns = ref.watch(customPatternsProvider);
    final preview = detectionLabPreviewTheme(ref);
    // The SAME resolver the runtime layers consult — the mini previews recolor
    // live as the store changes (slice-1 wiring).
    final resolver = DetectionStyleResolver(
      styles: styles,
      accent: preview.accent,
      backgroundBrightness: preview.brightness,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Detection lab')),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('detection-lab-list'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // Zone A: global. Master switch — one provider bit, three
            // surfaces (Settings toggle / session-menu glyph / here).
            SwitchListTile(
              key: const ValueKey('lab-master-toggle'),
              secondary: const Icon(Icons.search_outlined),
              title: const Text('Detect links & paths'),
              subtitle: const Text(
                'Master switch — the same setting as in Settings and the '
                'session menu.',
              ),
              value: detection.enabled,
              onChanged: (v) =>
                  ref.read(detectionSettingsProvider.notifier).setEnabled(v),
            ),
            ListTile(
              key: const ValueKey('lab-accent-note'),
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Highlight color: session theme'),
              subtitle: const Text(
                'Patterns follow the session accent unless a per-pattern '
                'color below overrides it.',
              ),
            ),
            const SettingsSubheader('Patterns'),
            for (final spec in detectionLabPatternSpecs)
              _PatternCard(
                spec: spec,
                detection: detection,
                resolver: resolver,
                preview: preview,
              ),
            // Zone C (#1031 slice 3): USER-DEFINED patterns — same card
            // anatomy, enable bit from the custom store, creation at the end
            // of the list it extends (per the IA).
            const SettingsSubheader('My patterns'),
            for (final pattern in customPatterns)
              _CustomPatternCard(
                pattern: pattern,
                detection: detection,
                resolver: resolver,
                preview: preview,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: FilledButton.tonalIcon(
                key: const ValueKey('lab-add-pattern'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DetectionLabPatternEditorScreen(),
                  ),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add pattern'),
              ),
            ),
            const SizedBox(height: 24),
            // Review change 4: the destructive lab-wide reset lives at the
            // BOTTOM, styled like the Settings reset (outlined, error color).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                key: const ValueKey('lab-reset-all-button'),
                onPressed: () => _confirmResetAll(context, ref),
                icon: const Icon(Icons.restart_alt),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                label: const Text('Reset lab customizations'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetAll(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(detectionStylesProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('lab-reset-all-dialog'),
        title: const Text('Reset lab customizations?'),
        content: const Text(
          'Restore every pattern\'s color, intensity, and behavior to the '
          'shipped defaults. The on/off switches and your saved detection '
          'exceptions are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('lab-reset-all-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await notifier.clearAllTuned();
  }
}

/// One pattern card: glyph + front-loaded name, the enable switch at the
/// right edge (thumb zone), a mini live preview line, chevron → detail.
class _PatternCard extends ConsumerWidget {
  const _PatternCard({
    required this.spec,
    required this.detection,
    required this.resolver,
    required this.preview,
  });

  final DetectionLabPatternSpec spec;
  final DetectionSettings detection;
  final DetectionStyleResolver resolver;
  final DetectionLabPreviewTheme preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = detectionLabTypeEnabled(detection, spec.key);
    return Card(
      key: ValueKey('lab-card-${spec.key}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: ValueKey('lab-card-tile-${spec.key}'),
            leading: Icon(spec.icon),
            title: Text(spec.title),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: ValueKey('lab-enable-${spec.key}'),
                  value: enabled,
                  // Master OFF greys the per-type switches (Settings idiom).
                  onChanged: detection.enabled
                      ? (v) => detectionLabSetTypeEnabled(ref, spec.key, v)
                      : null,
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DetectionLabDetailScreen(spec: spec),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: DetectionPreviewLine(
                key: ValueKey('lab-preview-${spec.key}'),
                spec: spec,
                resolver: resolver,
                background: preview.background,
                foreground: preview.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A USER-DEFINED pattern's card (#1031 slice 3): same anatomy as a built-in
/// (generic glyph, front-loaded name, right-edge enable switch, mini preview
/// over the author's own sample line, chevron → the shared detail page).
/// A stored regex that no longer compiles renders a visible ERROR state
/// instead of the preview and cannot be enabled (registration would skip it
/// anyway — auto-disabled on hydrate; never a silent drop, never a crash).
class _CustomPatternCard extends ConsumerWidget {
  const _CustomPatternCard({
    required this.pattern,
    required this.detection,
    required this.resolver,
    required this.preview,
  });

  final CustomPattern pattern;
  final DetectionSettings detection;
  final DetectionStyleResolver resolver;
  final DetectionLabPreviewTheme preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final spec = detectionLabSpecForCustomPattern(pattern);
    final broken = compileCustomPatternRegex(pattern.source) == null;
    return Card(
      key: ValueKey('lab-card-${pattern.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: ValueKey('lab-card-tile-${pattern.id}'),
            leading: Icon(spec.icon),
            title: Text(spec.title),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: ValueKey('lab-enable-${pattern.id}'),
                  value: pattern.enabled && !broken,
                  // Master OFF greys it (Settings idiom); a broken regex
                  // can't be enabled (fix it in the editor first).
                  onChanged: detection.enabled && !broken
                      ? (v) => ref
                            .read(customPatternsProvider.notifier)
                            .setEnabled(pattern.id, v)
                      : null,
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DetectionLabDetailScreen(spec: spec),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: broken
                ? Row(
                    key: ValueKey('lab-card-error-${pattern.id}'),
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Pattern disabled — its regex no longer compiles. '
                          'Open it to fix the expression.',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  )
                : spec.sampleMatch.isEmpty
                ? Text(
                    'No sample match — open the pattern to set a sample line.',
                    key: ValueKey('lab-card-nosample-${pattern.id}'),
                    style: theme.textTheme.bodySmall,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: DetectionPreviewLine(
                      key: ValueKey('lab-preview-${pattern.id}'),
                      spec: spec,
                      resolver: resolver,
                      background: preview.background,
                      foreground: preview.foreground,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
