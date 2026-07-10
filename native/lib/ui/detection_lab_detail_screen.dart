// Detection Lab per-pattern DETAIL page (#1031 slice 2).
//
// Anatomy per the reviewed IA:
//   - enable switch in the app bar (always visible, biggest target — the same
//     detectionSettingsProvider bit as Settings/root),
//   - the preview block PINNED under the app bar (review change 3: it must
//     never scroll away during a slider drag — it sits OUTSIDE the scrolling
//     controls list), labeled with its theme source (review change 2) and a
//     dark/light luminance override,
//   - states rendered HONESTLY (review change 1): "Detected" always; "Active
//     (verified)" ONLY where a real runtime active state exists (paths, #990),
//   - STYLE: color row (shared #1030 picker; cleared = session theme) +
//     intensity slider(s) whose min/max ARE the legibility band, the path pair
//     push-clamped so Active never inverts under Detected (review change 6),
//   - BEHAVIOR: only knobs that are REAL today (path verification gate,
//     command lexicon editor) — no disabled "coming" rows (review change 1),
//   - "Reset this pattern" at the BOTTOM behind a confirm (review change 4).
//
// The URL page writes id-level style to BOTH `url` and `osc8` (one
// user-facing type; reads resolve against the primary `url` id).

import 'package:flterm/flterm.dart' show kDefaultCommandLexicon;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/custom_patterns_providers.dart';
import '../state/detection_exceptions_providers.dart';
import '../state/detection_providers.dart';
import '../state/detection_style_providers.dart';
import '../storage/custom_patterns_store.dart';
import '../storage/detection_exceptions_store.dart';
import '../storage/detection_styles_store.dart';
import 'color_picker_sheet.dart';
import 'detection_lab_pattern_editor.dart';
import 'detection_lab_preview.dart';
import 'detection_style_resolver.dart';
import 'settings_subheader.dart';

class DetectionLabDetailScreen extends ConsumerStatefulWidget {
  const DetectionLabDetailScreen({super.key, required this.spec});

  final DetectionLabPatternSpec spec;

  @override
  ConsumerState<DetectionLabDetailScreen> createState() =>
      _DetectionLabDetailScreenState();
}

class _DetectionLabDetailScreenState
    extends ConsumerState<DetectionLabDetailScreen> {
  /// The live spec. For a USER-DEFINED pattern (#1031 slice 3) it re-derives
  /// from the CURRENT store record (build watches the provider) so an edit —
  /// rename, new regex, new sample — reflects immediately; the immutable id
  /// (`widget.spec.key`) is the stable handle. Falls back to the mount-time
  /// spec while the record is gone (mid-delete pop).
  DetectionLabPatternSpec get spec {
    if (!widget.spec.isCustom) return widget.spec;
    final live = ref.read(customPatternProvider(widget.spec.key));
    return live == null ? widget.spec : detectionLabSpecForCustomPattern(live);
  }

  /// Luminance override for the preview strip (null = follow the theme).
  Brightness? _luminance;

  /// In-flight slider values: the preview renders these live during a drag;
  /// the store is written once on release (avoids racing per-tick persists).
  double? _draftInactive;
  double? _draftActive;

  /// The stored styles with the in-flight drafts merged over this pattern's
  /// ids — what the pinned preview resolves against mid-drag.
  DetectionStyles _mergeDrafts(DetectionStyles base) {
    if (_draftInactive == null && _draftActive == null) return base;
    final map = Map<String, DetectionPatternStyle>.from(base.byPattern);
    for (final id in spec.styleIds) {
      final cur = base.of(id) ?? const DetectionPatternStyle();
      map[id] = DetectionPatternStyle(
        colorHex: cur.colorHex,
        inactiveIntensity: _draftInactive ?? cur.inactiveIntensity,
        activeIntensity: _draftActive ?? cur.activeIntensity,
        verifyShortPaths: cur.verifyShortPaths,
        lexicon: cur.lexicon,
      );
    }
    return DetectionStyles(map);
  }

  double _clampBand(double v) =>
      v.clamp(kDetectionIntensityMin, kDetectionIntensityMax);

  void _onInactiveChanged(double v, DetectionPatternStyle? stored) {
    if (spec.hasActiveState) {
      final pair = detectionResolveIntensityPair(
        inactive: v,
        active: _draftActive ?? stored?.activeIntensity ?? 1.0,
        activeDragged: false,
      );
      setState(() {
        _draftInactive = pair.inactive;
        _draftActive = pair.active;
      });
    } else {
      setState(() => _draftInactive = _clampBand(v));
    }
  }

  void _onActiveChanged(double v, DetectionPatternStyle? stored) {
    final pair = detectionResolveIntensityPair(
      inactive: _draftInactive ?? stored?.inactiveIntensity ?? 1.0,
      active: v,
      activeDragged: true,
    );
    setState(() {
      _draftInactive = pair.inactive;
      _draftActive = pair.active;
    });
  }

  /// Write the drafts through the store on slider release — the runtime
  /// affordances re-resolve immediately via the slice-1 provider watch.
  Future<void> _commitIntensities() async {
    final notifier = ref.read(detectionStylesProvider.notifier);
    final inactive = _draftInactive;
    final active = _draftActive;
    for (final id in spec.styleIds) {
      if (inactive != null) await notifier.setInactiveIntensity(id, inactive);
      if (active != null && spec.hasActiveState) {
        await notifier.setActiveIntensity(id, active);
      }
    }
    if (mounted) {
      setState(() {
        _draftInactive = null;
        _draftActive = null;
      });
    }
  }

  Future<void> _pickColor(Color effectiveAccent) async {
    final notifier = ref.read(detectionStylesProvider.notifier);
    final stored = ref.read(detectionStylesProvider).of(spec.primaryId);
    final result = await showColorPickerSheet(
      context,
      initial: detectionColorFromHex(stored?.colorHex) ?? effectiveAccent,
      title: '${spec.title}: highlight color',
      clearLabel: 'Use theme color',
      previewLabel: spec.sampleMatch,
    );
    if (result == null) return; // cancelled
    final hex = result.color == null ? null : hexFromColor(result.color!);
    for (final id in spec.styleIds) {
      await notifier.setColorHex(id, hex);
    }
  }

  Future<void> _confirmResetPattern() async {
    final notifier = ref.read(detectionStylesProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('lab-reset-pattern-dialog'),
        title: Text('Reset ${spec.title}?'),
        content: const Text(
          'Restore this pattern\'s color, intensity, and behavior to the '
          'shipped defaults. The on/off switch and your saved detection '
          'exceptions are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('lab-reset-pattern-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final id in spec.styleIds) {
      await notifier.resetPattern(id);
    }
  }

  Future<void> _openLexiconEditor() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LexiconEditorSheet(spec: spec),
    );
  }

  /// Delete a USER-DEFINED pattern (#1031 slice 3). The confirm DISCLOSES the
  /// #995 exception-family pruning (IA review change 5: deleting authored
  /// data as a side effect must be stated at the moment it happens), then
  /// prunes the family, drops the TUNED style entry, removes the record, and
  /// pops back to the lab root.
  Future<void> _confirmDeleteCustom(CustomPattern custom) async {
    final family = detectionExceptionFamily(custom.id);
    final exceptionCount = ref
        .read(detectionExceptionsProvider)
        .where((e) => e.family == family)
        .length;
    final disclosure = exceptionCount > 0
        ? 'Also removes $exceptionCount saved detection '
              'exception${exceptionCount == 1 ? '' : 's'} reported for it.'
        : 'No saved detection exceptions reference it.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('lab-custom-delete-dialog'),
        title: Text('Delete "${custom.name}"?'),
        content: Text(
          'Remove this pattern and its color and intensity tuning. '
          '$disclosure',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('lab-custom-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(detectionExceptionsProvider.notifier).pruneFamily(custom.id);
    await ref.read(detectionStylesProvider.notifier).resetPattern(custom.id);
    await ref.read(customPatternsProvider.notifier).remove(custom.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detection = ref.watch(detectionSettingsProvider);
    // #1031 slice 3: the live custom record (null for built-ins / mid-delete)
    // — watching keeps title/sample/enable current across edits.
    final custom = widget.spec.isCustom
        ? ref.watch(customPatternProvider(widget.spec.key))
        : null;
    final customBroken =
        custom != null && compileCustomPatternRegex(custom.source) == null;
    final styles = ref.watch(detectionStylesProvider);
    final stored = styles.of(spec.primaryId);
    final preview = detectionLabPreviewTheme(ref, luminanceOverride: _luminance);
    final resolver = DetectionStyleResolver(
      styles: _mergeDrafts(styles),
      accent: preview.accent,
      backgroundBrightness: preview.brightness,
    );
    final enabled = widget.spec.isCustom
        ? (custom?.enabled ?? false) && !customBroken
        : detectionLabTypeEnabled(detection, spec.key);
    final inactiveValue =
        _clampBand(_draftInactive ?? stored?.inactiveIntensity ?? 1.0);
    final activeValue =
        _clampBand(_draftActive ?? stored?.activeIntensity ?? 1.0);
    final effectiveLexicon = stored?.lexicon ?? kDefaultCommandLexicon;

    return Scaffold(
      appBar: AppBar(
        title: Text(spec.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Switch(
              key: const ValueKey('lab-detail-enable'),
              value: enabled,
              // Master OFF greys it; a custom pattern flips its OWN store bit
              // (a broken regex can't be enabled — fix it in the editor).
              onChanged: !detection.enabled
                  ? null
                  : widget.spec.isCustom
                  ? (custom == null || customBroken
                        ? null
                        : (v) => ref
                              .read(customPatternsProvider.notifier)
                              .setEnabled(custom.id, v))
                  : (v) => detectionLabSetTypeEnabled(ref, spec.key, v),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // PINNED preview (review change 3): lives OUTSIDE the scrolling
            // controls list so a slider drag / keyboard can never push it
            // off-screen.
            Material(
              key: const ValueKey('lab-detail-preview'),
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview.sourceLabel,
                            key: const ValueKey('lab-preview-source'),
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SegmentedButton<Brightness>(
                          key: const ValueKey('lab-preview-luminance'),
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: Brightness.dark,
                              icon: Icon(Icons.dark_mode_outlined),
                              tooltip: 'Preview on a dark terminal',
                            ),
                            ButtonSegment(
                              value: Brightness.light,
                              icon: Icon(Icons.light_mode_outlined),
                              tooltip: 'Preview on a light terminal',
                            ),
                          ],
                          selected: {preview.brightness},
                          onSelectionChanged: (sel) =>
                              setState(() => _luminance = sel.first),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DetectionPreviewLine(
                            key: const ValueKey('lab-detail-preview-detected'),
                            spec: spec,
                            resolver: resolver,
                            background: preview.background,
                            foreground: preview.foreground,
                            stateLabel: 'Detected',
                          ),
                          // Review change 1: the active state renders ONLY
                          // where it exists at runtime (verified paths, #990).
                          if (spec.hasActiveState)
                            DetectionPreviewLine(
                              key: const ValueKey('lab-detail-preview-active'),
                              spec: spec,
                              resolver: resolver,
                              background: preview.background,
                              foreground: preview.foreground,
                              verified: true,
                              stateLabel: 'Active (verified)',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                key: const ValueKey('lab-detail-controls'),
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  // #1031 slice 3: a custom pattern's DEFINITION — name/regex
                  // edit via the shared editor (create and edit are one
                  // screen; the id never changes, review change 5).
                  if (widget.spec.isCustom) ...[
                    const SettingsSubheader('Definition'),
                    ListTile(
                      key: const ValueKey('lab-custom-edit-row'),
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Edit pattern'),
                      subtitle: Text(
                        customBroken
                            ? 'Regex no longer compiles — open to fix it.'
                            : custom?.source ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: customBroken
                            ? TextStyle(color: theme.colorScheme.error)
                            : const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: custom == null
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    DetectionLabPatternEditorScreen(
                                      existing: custom,
                                    ),
                              ),
                            ),
                    ),
                  ],
                  const SettingsSubheader('Style'),
                  ListTile(
                    key: const ValueKey('lab-color-row'),
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Highlight color'),
                    subtitle: Text(
                      stored?.colorHex == null
                          ? 'Session theme'
                          : stored!.colorHex!,
                    ),
                    trailing: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: resolver
                            .resolveStyle(spec.primaryId, verified: false)
                            .chipAccent
                            .withValues(alpha: 1.0),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    onTap: () => _pickColor(preview.accent),
                  ),
                  const ListTile(
                    key: ValueKey('lab-inactive-title'),
                    title: Text('Detected intensity'),
                    dense: true,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Slider(
                      key: const ValueKey('lab-inactive-slider'),
                      // Review change 6: the band IS the slider — every
                      // position changes something visible; no numeric
                      // multiplier (the pinned preview is the value).
                      min: kDetectionIntensityMin,
                      max: kDetectionIntensityMax,
                      value: inactiveValue,
                      onChanged: (v) => _onInactiveChanged(v, stored),
                      onChangeEnd: (_) => _commitIntensities(),
                    ),
                  ),
                  if (spec.hasActiveState) ...[
                    const ListTile(
                      key: ValueKey('lab-active-title'),
                      title: Text('Active intensity (verified)'),
                      dense: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Slider(
                        key: const ValueKey('lab-active-slider'),
                        min: kDetectionIntensityMin,
                        max: kDetectionIntensityMax,
                        value: activeValue,
                        onChanged: (v) => _onActiveChanged(v, stored),
                        onChangeEnd: (_) => _commitIntensities(),
                      ),
                    ),
                  ],
                  // BEHAVIOR: only knobs that are REAL today (review change
                  // 1). URLs have none → no section at all.
                  if (spec.key == 'path' || spec.key == 'command')
                    const SettingsSubheader('Behavior'),
                  if (spec.key == 'path')
                    SwitchListTile(
                      key: const ValueKey('lab-verify-toggle'),
                      secondary: const Icon(Icons.verified_outlined),
                      title: const Text('Short-path verification'),
                      subtitle: const Text(
                        'Hide one-segment paths (like /config) until SFTP '
                        'confirms they exist on the host.',
                      ),
                      value: stored?.verifyShortPaths ?? true,
                      onChanged: (v) => ref
                          .read(detectionStylesProvider.notifier)
                          // ON is the shipped default → store nothing.
                          .setVerifyShortPaths(
                            spec.primaryId,
                            v ? null : false,
                          ),
                    ),
                  if (spec.key == 'command')
                    ListTile(
                      key: const ValueKey('lab-lexicon-row'),
                      leading: const Icon(Icons.menu_book_outlined),
                      title: const Text('Command lexicon'),
                      subtitle: Text(
                        '${effectiveLexicon.length} words — a first token on '
                        'this list scores as a command.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openLexiconEditor,
                    ),
                  const SizedBox(height: 24),
                  // Review change 4: per-pattern reset at the page BOTTOM.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton.icon(
                      key: const ValueKey('lab-reset-pattern-button'),
                      onPressed: _confirmResetPattern,
                      icon: const Icon(Icons.restart_alt),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      label: const Text('Reset this pattern'),
                    ),
                  ),
                  // #1031 slice 3: delete (custom only) — LAST, below reset;
                  // the confirm discloses the exception pruning.
                  if (widget.spec.isCustom) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: OutlinedButton.icon(
                        key: const ValueKey('lab-custom-delete-button'),
                        onPressed: custom == null
                            ? null
                            : () => _confirmDeleteCustom(custom),
                        icon: const Icon(Icons.delete_outline),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        label: const Text('Delete pattern'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The command-lexicon editor sheet: add a word, remove a word (chip delete),
/// or restore the app-supplied default list (clears the stored override).
class _LexiconEditorSheet extends ConsumerStatefulWidget {
  const _LexiconEditorSheet({required this.spec});

  final DetectionLabPatternSpec spec;

  @override
  ConsumerState<_LexiconEditorSheet> createState() =>
      _LexiconEditorSheetState();
}

class _LexiconEditorSheetState extends ConsumerState<_LexiconEditorSheet> {
  final TextEditingController _addCtrl = TextEditingController();

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  List<String> get _effective =>
      ref.read(detectionStylesProvider).of(widget.spec.primaryId)?.lexicon ??
      kDefaultCommandLexicon;

  Future<void> _add() async {
    final word = _addCtrl.text.trim();
    _addCtrl.clear();
    if (word.isEmpty) return;
    final current = _effective;
    if (current.contains(word)) return;
    await ref
        .read(detectionStylesProvider.notifier)
        .setLexicon(widget.spec.primaryId, [...current, word]);
  }

  Future<void> _remove(String word) async {
    await ref.read(detectionStylesProvider.notifier).setLexicon(
          widget.spec.primaryId,
          [..._effective]..remove(word),
        );
  }

  Future<void> _restoreDefault() async {
    await ref
        .read(detectionStylesProvider.notifier)
        .setLexicon(widget.spec.primaryId, null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stored = ref
        .watch(detectionPatternStyleProvider(widget.spec.primaryId))
        ?.lexicon;
    final effective = stored ?? kDefaultCommandLexicon;
    return Padding(
      // Keep the add field above the soft keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          key: const ValueKey('lab-lexicon-editor'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Command lexicon',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    stored == null
                        ? '${effective.length} words (default list)'
                        : '${effective.length} words (customized)',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('lab-lexicon-add-field'),
                          controller: _addCtrl,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'Add a word',
                            hintText: 'kubectl',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => _add(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('lab-lexicon-add-button'),
                        onPressed: _add,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('lab-lexicon-restore-default'),
                      onPressed: _restoreDefault,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Restore default list'),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final word in effective)
                      InputChip(
                        key: ValueKey('lab-lexicon-chip-$word'),
                        label: Text(word),
                        // Explicit glyph (M3 defaults to clear) so tests and
                        // the monochrome-icon rule stay stable.
                        deleteIcon: const Icon(Icons.cancel),
                        onDeleted: () => _remove(word),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
