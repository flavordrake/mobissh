// User-defined pattern EDITOR (#1031 slice 3) — one screen for create and
// edit, per the reviewed IA.
//
// Mandatory path = three fields: name, regex, sample line. The regex is
// compiled LIVE in a defensive try (never a crash): a compile error renders
// INLINE under the field and blocks Save; an empty sample match is a NOTE,
// never a block (the sample may simply not contain a hit). The sample line
// echoes what the pattern matches — the matched spans render highlighted so
// the author sees exactly what the terminal will decorate.
//
// Identity (IA review change 5): the id is minted ONCE at creation, by the
// store — this screen never touches it. Editing (rename / regex / sample)
// updates the record IN PLACE under the same id, so the style entry, the
// enable bit, and the #995 exception family never orphan.
//
// Tier is fixed to SPAN in v1 (the #767 default; block + trailing-trim are a
// later slice) and the tap action is "Copy match" — both deliberate IA cuts.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/custom_patterns_providers.dart';
import '../storage/custom_patterns_store.dart';

class DetectionLabPatternEditorScreen extends ConsumerStatefulWidget {
  const DetectionLabPatternEditorScreen({super.key, this.existing});

  /// The pattern being edited, or null to create a new one.
  final CustomPattern? existing;

  @override
  ConsumerState<DetectionLabPatternEditorScreen> createState() =>
      _DetectionLabPatternEditorScreenState();
}

class _DetectionLabPatternEditorScreenState
    extends ConsumerState<DetectionLabPatternEditorScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _regex = TextEditingController(
    text: widget.existing?.source ?? '',
  );
  late final TextEditingController _sample = TextEditingController(
    text: widget.existing?.sampleLine ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _regex.dispose();
    _sample.dispose();
    super.dispose();
  }

  String? get _regexError => customPatternRegexError(_regex.text);

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      compileCustomPatternRegex(_regex.text) != null;

  Future<void> _save() async {
    final notifier = ref.read(customPatternsProvider.notifier);
    final name = _name.text.trim();
    final source = _regex.text;
    final sample = _sample.text;
    final existing = widget.existing;
    if (existing == null) {
      await notifier.create(name: name, source: source, sampleLine: sample);
    } else {
      // Review change 5: the id NEVER changes on edit.
      await notifier.updatePattern(
        existing.id,
        name: name,
        source: source,
        sampleLine: sample,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// The non-empty match spans of the current regex over the sample line.
  List<Match> _sampleMatches() {
    final regex = compileCustomPatternRegex(_regex.text);
    final sample = _sample.text;
    if (regex == null || sample.isEmpty) return const [];
    return [
      for (final m in regex.allMatches(sample))
        if (m.end > m.start) m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final regexError = _regexError;
    final matches = _sampleMatches();
    final sample = _sample.text;
    final highlight = theme.colorScheme.primary.withValues(alpha: 0.30);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New pattern' : 'Edit pattern'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('lab-custom-save'),
              onPressed: _canSave ? _save : null,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const ValueKey('lab-custom-name'),
              controller: _name,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Jira tickets',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('lab-custom-regex'),
              controller: _regex,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'Regular expression',
                hintText: r'[A-Z]{2,}-\d+',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            // Live inline compile error (never a crash; Save stays blocked).
            if (regexError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Invalid regex: $regexError',
                  key: const ValueKey('lab-custom-regex-error'),
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('lab-custom-sample'),
              controller: _sample,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'Sample line to validate against',
                hintText: 'fixed in PROJ-1234 yesterday',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (sample.isNotEmpty && regexError == null) ...[
              const SizedBox(height: 8),
              // The echo: matched payload(s), or the honest no-match NOTE
              // (a warning, never a Save block — the IA's creation-flow rule).
              Text(
                matches.isEmpty
                    ? 'no match on this line'
                    : 'matched: ${matches.map((m) => '"${sample.substring(m.start, m.end)}"').join(', ')}',
                key: const ValueKey('lab-custom-sample-echo'),
                style: theme.textTheme.bodySmall,
              ),
              if (matches.isNotEmpty) ...[
                const SizedBox(height: 8),
                // The sample line with the match spans highlighted — the
                // author sees exactly what the terminal will decorate.
                Text.rich(
                  TextSpan(children: _highlightSpans(sample, matches, highlight)),
                  key: const ValueKey('lab-custom-sample-highlight'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Split [sample] into plain / highlighted spans at [matches] (non-empty,
  /// in order, non-overlapping — allMatches guarantees both).
  static List<TextSpan> _highlightSpans(
    String sample,
    List<Match> matches,
    Color highlight,
  ) {
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: sample.substring(cursor, m.start)));
      }
      spans.add(
        TextSpan(
          text: sample.substring(m.start, m.end),
          style: TextStyle(backgroundColor: highlight),
        ),
      );
      cursor = m.end;
    }
    if (cursor < sample.length) {
      spans.add(TextSpan(text: sample.substring(cursor)));
    }
    return spans;
  }
}
